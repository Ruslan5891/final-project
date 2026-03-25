## Інфраструктура AWS з використанням Terraform, Jenkins та Argo CD

Цей проєкт демонструє повний цикл розгортання Django-застосунку в AWS з використанням Terraform (інфраструктура), Jenkins (CI) та Argo CD (CD).

---

## Структура проєкту

```text
final-project/
├── main.tf               # Головний файл, підключення всіх модулів
├── backend.tf            # Налаштування бекенду для стейтів (S3 + DynamoDB)
├── outputs.tf            # Загальні виводи ресурсів
├── variables.tf          # Кореневі змінні
├── modules/
    ├── s3-backend/       # S3 + DynamoDB для зберігання Terraform state
    ├── vpc/              # VPC, підмережі, маршрути, Internet Gateway
    ├── ecr/              # ECR репозиторій для Docker-образів
    ├── eks/              # EKS кластер та node group
    ├── jenkins/          # Jenkins, встановлений через Helm
    └── argo_cd/          # Argo CD + Helm-чарт з Application'ами
    └── rds/              # RDS Модуль бази даних або aurora кластера
    └── monitoring/       # Prometheus + Grafana (kube-prometheus-stack)

```

### Огляд модулів

- **`modules/s3-backend`** – створює S3-бакет з версіонуванням для `terraform.tfstate` та таблицю DynamoDB для блокування стейту.
- **`modules/vpc`** – формує мережеву інфраструктуру (VPC, публічні/приватні підмережі, Internet Gateway, таблиці маршрутів).
- **`modules/ecr`** – створює репозиторій **ECR** для зберігання Docker-образів (`final-project-ecr`).
- **`modules/eks`** – підіймає керований кластер **Amazon EKS**, node group та IAM-ролі (в т.ч. для доступу до ECR).
- **`modules/jenkins`** – розгортає **Jenkins** у namespace `jenkins` через Helm, додає:
  - `StorageClass`;
  - namespace `jenkins`;
  - service account `jenkins-sa` з IAM-роллю для Kaniko (доступ до ECR);
  - Helm release `jenkins` з JCasC-конфігурацією (seed-job, креденшели GitHub).
- **`modules/argo_cd`** – розгортає **Argo CD** (Helm release `argo_cd`) та окремий Helm-чарт з:
  - ArgoCD `Application`, який слідкує за репозиторієм `final-project` (`charts/django-app`);
  - `Secret` типу `repository` для підключення GitHub-репозиторію.
- **`modules/rds`** – підіймає базу данних по типу **PostgreSQL** або більш швидку базу aurora
- **`modules/monitoring`** – встановлює **kube-prometheus-stack** (Prometheus + Grafana) у namespace `monitoring`

---

## Розгортання інфраструктури (Terraform)

Перед початком переконайтеся, що:

- налаштований AWS CLI (`aws configure`);
- встановлені `terraform`, `kubectl`, `helm`;
- є права створювати EKS, ECR, S3, DynamoDB, VPC, IAM ролі.

> Для першого запуску бекенд S3 у `backend.tf` можна залишити закоментованим, щоб стейт був локальним. Пізніше його можна перенести в S3 (див. розділ про бекенд).

### Крок 1. Ініціалізація

```bash
cd final-project
terraform init
```

**Що відбувається:** завантажуються провайдери (`aws`, `kubernetes`, `helm`) та ініціалізуються модулі (`s3-backend`, `vpc`, `ecr`, `eks`, `jenkins`, `argo_cd`, `rds`, `monitoring`).

### Крок 2. Планування

```bash
terraform plan
```

**Що відбувається:** Terraform показує список ресурсів, які будуть створені/змінені/видалені. На цьому етапі зручно перевірити:

- CIDR-блоки VPC та підмереж;
- назви кластера EKS та ECR-репозиторію;
- інші параметри модулів.

### Крок 3. Застосування

```bash
terraform apply
# підтвердити: yes
```

**Що створюється:**

- S3-бакет та DynamoDB таблиця для стейтів (`modules/s3-backend`);
- VPC з публічними та приватними підмережами (`modules/vpc`);
- репозиторій **ECR** `final-project-ecr` (`modules/ecr`);
- кластер **EKS** з node group та OIDC-провайдером (`modules/eks`);
- **Jenkins** (Helm release `jenkins`) (`modules/jenkins`);
- **Argo CD** + Helm-чарт з Application'ами (`modules/argo_cd`).

Після успішного створення оновіть `kubeconfig`, щоб `kubectl` працював з EKS:

```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-cluster-demo
```

---

## Перевірка CI: Jenkins і оновлення Docker-образу

### Доступ до Jenkins

Jenkins розгорнутий в namespace `jenkins`.

Подивитися сервіс:

```bash
kubectl get svc -n jenkins
```

- Якщо тип `LoadBalancer` – відкрийте EXTERNAL-IP/hostname у браузері.
- Якщо `ClusterIP` – використайте порт-форвардинг:

```bash
kubectl port-forward svc/jenkins 8080:80 -n jenkins
```

і відкрийте `http://localhost:8080`.

Облікові дані адміністратора (з `modules/jenkins/values.yaml`):

- логін: `admin`
- пароль: `admin123`

> У реальних середовищах ці дані потрібно винести в секрети.

### Seed job і pipeline

Jenkins налаштований через **Jenkins Configuration as Code (JCasC)** і при старті:

- створює credential `github-token` для доступу до GitHub;
- створює seed-job, який генерує pipeline job для репозиторію:
  - `https://github.com/Ruslan5891/final-project`

У результаті в UI Jenkins з’являється pipeline (наприклад, `goit-django-docker`), який працює з репозиторієм `final-project`.

### Логіка Jenkins pipeline

`Jenkinsfile` лежить у репозиторії `final-project` і містить дві основні стадії:

1. **Build & Push Docker Image**
   - запускається Kubernetes-агент з контейнерами:
     - `kaniko` – збирає Docker-образ без Docker daemon;
     - `git` – для роботи з Git;
   - збирається образ за `Dockerfile` поточного репозиторію;
   - образ пушиться в **Amazon ECR**:
     - реєстр: `122610492747.dkr.ecr.eu-central-1.amazonaws.com`;
     - репозиторій: `final-project-ecr`;
     - тег: `v1.0.${BUILD_NUMBER}` (унікальний для кожного білду).

2. **Update Chart Tag in Git**
   - клонування репозиторію `final-project`;
   - перехід до `charts/django-app/values.yaml`;
   - оновлення рядка `tag: ...` на новий тег образу (`IMAGE_TAG`);
   - `git add`, `git commit`, `git push` у гілку `main`.

**Результат:**  
кожний успішний запуск pipeline створює новий тег образу в ECR і оновлює Helm values-файл у Git (`final-project`).

### Де подивитися оновлений образ і тег

- **AWS ECR консоль** – репозиторій `final-project-ecr` (регіон `eu-central-1`), список тегів: `v1.0.X`.
- **GitHub `final-project`** – файл `charts/django-app/values.yaml`, поле `image.tag` міститиме останній тег.

### Налаштування в інтерфейсі Jenkins

Для того, щоб автоматизувати процес пушу нових данних, вам необхідно Jenkins провалитися в seed-job. Після цього вам необхідно перейти в 
налаштування і для розділу трігерів збірки поставити голчку напроти GitHub hook trigger for GITScm polling і зберенти ці зміни. Після цього вам необхідно перейти в репозиторій де лежить ваш сам додаток і там необхідно налаштувати вебхук. Тобто в своєму репозиторіі ви заходите в Settings, в лівій менюшці клікаєте по розділу Webhooks, після цього клікаєте на кнопу Add webhook. В полі Payload URL вам необхідно скопіювати урл по якому відкривається ваш Jenkins в браузері і через слеш до цього урла додати github-webhook, в моєму випдку це "http://a84c8e06a20854288856e3f8db650c62-1406678177.eu-central-1.elb.amazonaws.com/github-webhook/." Далі в полі Content type вибираєте значення application/json. І після цього клікаєте зберегти. Після того як ви налаштували це, вам необхідно зібрати вашу джобу seed-job клікнувши всередині джоби на кнопку "Зібрати зараз". Ваша джоба в перший раз скоріше за все зафейлиться і тому вам треба додатково вийти в рутову директорію вашого Jenkins. Зліва в меню у вас буде кнока "Налаштувати Jenkins", клікаєтесь по ній і провалюєтесь в внутрішнє меню. Шукаєте блок "Security" в цьому меню має бути сабменюшка, яка називається In-process Script Approval, зоходите в неї і там клікаїте Approve для Groovy script із назвою вашої джоби "goit-django-docker". Після цього повертаєтеся назад в seed-job і перезапускаєте заново збірку вашої джоби. Після того, як виконалася ця джоба у вас має з"явитися нова джоба з назвою goit-django-docker, вона відповідає за розгортання і оновлення django додатку, який моніториться через Argo CD.

## Перевірка CD: Argo CD і оновлення релізу

### Доступ до Argo CD

Argo CD розгорнуто в namespace `argocd`.

Подивитися сервіс:

```bash
kubectl get svc -n argocd
```

Сервіс Argo CD налаштовано як `LoadBalancer` (див. `modules/argo_cd/values.yaml`). Точну назву сервісу можна подивитися командою `kubectl get svc -n argocd`, а UI відкрийте за `EXTERNAL-IP/hostname`:

```text
https://<ARGOCD_LOADBALANCER_IP>
```

Початковий пароль користувача `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Авторизація:

- користувач: `admin`
- пароль: значення з команди вище.

### Argo CD Application, що слідкує за `final-project`

У `modules/argo_cd/charts/values.yaml` описане Application з такими параметрами:

- `repoURL`: `https://github.com/Ruslan5891/final-project`
- `path`: `charts/django-app`
- `targetRevision`: `main`
- `syncPolicy.automated` з `prune: true` та `selfHeal: true`
- `destination`: кластер `https://kubernetes.default.svc`, namespace `default`.

**Що це дає:**

- Argo CD постійно слідкує за гілкою `main` у `final-project`;
- кожне оновлення `values.yaml` (новий тег образу від Jenkins) автоматично призводить до синхронізації Helm-чарту в кластері EKS.

### Як перевірити, що Argo CD оновив реліз

1. Відкрити Argo CD UI та знайти Application (наприклад, `example-app`).
2. Переконатися, що статус `Synced` і `Healthy`.
3. Відкрити вкладку **History** й побачити новий sync, який відповідає останньому коміту Jenkins у `final-project`.
4. Додатково перевірити в кластері:

```bash
kubectl get pods -n default
kubectl describe deployment <release-name>-django -n default
```

У полі `Image` в `describe deployment` ви побачите оновлений тег образу (`final-project-ecr:v1.0.X`) з ECR.

---

## Перевірка моніторингу: Prometheus та Grafana

Моніторинг встановлюється через Helm-чарт `kube-prometheus-stack` у namespace `monitoring`.

1. Перевірити, що компоненти піднялись:
```bash
kubectl get all -n monitoring
kubectl get svc -n monitoring | grep -E "grafana|prometheus"
```

2. Grafana:
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```
Після цього відкрий у браузері: `http://localhost:3000`

Логін: `admin`  
Пароль дістаньте з secret:
```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

3. Prometheus:
```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
```
Після цього відкрий у браузері: `http://localhost:9090`

---

## Налаштування віддаленого backend (S3)

Після того, як модуль `s3-backend` створив S3-бакет і таблицю DynamoDB, можна перенести локальний Terraform state у S3.

1. Відкрийте файл `backend.tf` та **розкоментуйте** блок:

```bash
terraform {
  backend "s3" {
    bucket         = "final-project-terraform-state-bucket-test"
    key            = "final-project/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

2. Перезапустіть ініціалізацію:

```bash
terraform init
```

Terraform виявить зміну конфігурації бекенду та запропонує **мігрувати локальний стейт у S3** – підтвердьте (`yes`).

3. Перевірте консоль AWS S3 – у бакеті має з’явитися об’єкт `final-project/terraform.tfstate`.  
   DynamoDB-таблиця використовується для блокування стейту при одночасних змінах.

---
### Модуль RDS — приклад використання та змінні

Модуль створює **Aurora Cluster** або звичайну **RDS instance** залежно від змінної `use_aurora` (true — Aurora, false — одна RDS instance). Автоматично створюються DB Subnet Group, Security Group та Parameter Group.

#### Приклад використання модуля

```hcl
module "rds" {
  source = "./modules/rds"

  name                 = "myapp-db"
  use_aurora           = true
  db_name              = "myapp"
  username             = "postgres"
  password             = "your-secure-password"
  vpc_id               = module.vpc.vpc_id
  subnet_private_ids   = module.vpc.private_subnets
  subnet_public_ids    = module.vpc.public_subnets

  engine_cluster             = "aurora-postgresql"
  engine_version_cluster     = "15.8"
  parameter_group_family_aurora = "aurora-postgresql15"

  engine                     = "postgres"
  engine_version             = "17.2"
  parameter_group_family_rds  = "postgres17"

  instance_class          = "db.t3.medium"
  allocated_storage        = 20
  multi_az                = true
  publicly_accessible     = false
  backup_retention_period = 7
  parameters = {
    max_connections            = "200"
    log_min_duration_statement = "500"
  }
  tags = { Environment = "dev", Project = "myapp" }
}
```

## Змінні модуля RDS

### Основні

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **name** | `string` | — | Унікальна назва інстансу або кластера. Використовується в ідентифікаторах ресурсів (DB instance, cluster, subnet group, security group, parameter group). |
| **use_aurora** | `bool` | `false` | Режим роботи: `true` — створюється **Aurora Cluster** (writer + опційно readers), `false` — одна **звичайна RDS instance**. Впливає на те, які ресурси створюються (cluster vs single instance). |
| **db_name** | `string` | — | Назва бази даних, яка створюється при першому запуску. Обов’язкова для створення БД. |
| **username** | `string` | — | Ім’я головного користувача БД (майстер-користувач). Використовується для підключення до БД. |
| **password** | `string` | — | Пароль майстер-користувача. Позначається як `sensitive`, щоб не потрапляв у логи та plan. |

### Мережа та безпека

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **vpc_id** | `string` | — | ID VPC, в якій створюються RDS/Aurora. Потрібен для Security Group та розміщення БД у потрібній мережі. |
| **subnet_private_ids** | `list(string)` | — | Список ID **приватних** підмереж. Використовується в DB Subnet Group, коли БД не публічна (`publicly_accessible = false`). |
| **subnet_public_ids** | `list(string)` | — | Список ID **публічних** підмереж. Використовується в DB Subnet Group, коли БД публічна (`publicly_accessible = true`). |
| **publicly_accessible** | `bool` | `false` | Чи отримує інстанс публічну IP і чи можна підключатися з інтернету. Впливає на вибір підмереж у DB Subnet Group та налаштування мережі. |

### Двигун і версія (RDS — звичайна instance)

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **engine** | `string` | `"postgres"` | Двигун БД для **звичайної RDS**: `postgres`, `mysql` тощо. Визначає тип СУБД. |
| **engine_version** | `string` | `"14.7"` | Версія двигуна для RDS (наприклад `14.7`, `17.2` для PostgreSQL). Має відповідати версіям, підтримуваним AWS у вашому регіоні. |
| **parameter_group_family_rds** | `string` | `"postgres15"` | Сімейство **DB parameter group** для RDS (наприклад `postgres14`, `postgres17`, `mysql8.0`). Має відповідати двигуну та версії. |

### Двигун і версія (Aurora)

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **engine_cluster** | `string` | `"aurora-postgresql"` | Двигун для **Aurora**: `aurora-postgresql` або `aurora-mysql`. Визначає тип Aurora-кластера. |
| **engine_version_cluster** | `string` | `"15.3"` | Версія двигуна Aurora (наприклад `15.8` для Aurora PostgreSQL). Має бути доступною в регіоні (перевіряти через `aws rds describe-db-engine-versions`). |
| **parameter_group_family_aurora** | `string` | `"aurora-postgresql15"` | Сімейство **cluster parameter group** для Aurora (наприклад `aurora-postgresql15`, `aurora-mysql8.0`). Має відповідати версії Aurora. |

### Ресурси інстансу

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **instance_class** | `string` | `"db.t3.micro"` | Клас інстансу: CPU/RAM (наприклад `db.t3.micro`, `db.t3.medium`, `db.r6g.large`). Однаковий для RDS і для нод Aurora. |
| **allocated_storage** | `number` | `20` | Розмір диску в **ГБ** тільки для **звичайної RDS**. Для Aurora розмір зберігання керується автоматично. |

### Aurora: кількість інстансів

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **aurora_replica_count** | `number` | `1` | Кількість **reader**-інстансів у Aurora. `0` — тільки writer; `1` і більше — writer + вказана кількість readers для читання. |
| **aurora_instance_count** | `number` | `2` | Загальна кількість інстансів у кластері (1 writer + replicas). Може використовуватися для обчислення кількості readers. |

### Відмовостійкість і бекапи

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **multi_az** | `bool` | `false` | Тільки для **RDS**: розгортання standby-репліки в іншій AZ для failover. Для Aurora не використовується (Aurora вже розподілена по AZ). |
| **backup_retention_period** | `string` / `number` | `""` | Скільки **днів** зберігати автоматичні бекапи. Наприклад `7` або `30`. Порожнє — використовується дефолт провайдера. |

### Параметри БД

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **parameters** | `map(string)` | `{}` | Додаткові параметри **parameter group** (наприклад `max_connections`, `work_mem`, `log_statement`). Застосовуються до RDS і до Aurora. |

### Службові

| Змінна | Тип | За замовчуванням | Призначення |
|--------|-----|------------------|-------------|
| **tags** | `map(string)` | `{}` | Теги для всіх створюваних ресурсів (instance, cluster, subnet group, security group, parameter groups). Для білінгу та організації ресурсів. |


## Як змінити параметри RDS

### Що змінити (у виклику модуля `rds` у `main.tf`)

| Що потрібно | Змінна (-ні) | Приклад |
|-------------|----------------|---------|
| **Тип БД** (PostgreSQL/MySQL) | `engine` (RDS) або `engine_cluster` (Aurora) | `"postgres"` / `"aurora-postgresql"` |
| **Версія двигуна** | `engine_version` (RDS) або `engine_version_cluster` (Aurora) | `"15.8"`, `"17.2"` |
| **Клас інстансу** (CPU/RAM) | `instance_class` | `db.t3.micro`, `db.t3.medium`, `db.r6g.large` |
| **Aurora чи RDS** | `use_aurora` | `true` — Aurora, `false` — звичайна RDS |
| **Розмір диску** (тільки RDS) | `allocated_storage` (ГБ) | `20`, `50`, `100` |
| **Кількість readers** (Aurora) | `aurora_replica_count` | `0`, `1`, `2` |
| **Parameter group** (під версію) | `parameter_group_family_rds` / `parameter_group_family_aurora` | `"postgres17"`, `"aurora-postgresql15"` |

Після зміни цих змінних збережи `main.tf`.


### Як застосувати зміни

1. **Переконайся, що змінюються саме потрібні ресурси** (RDS instance / Aurora cluster тощо) — переглянь вивід `terraform plan`.

2. **Застосуй:**
   ```bash
   terraform apply
   ```
---

## Видалення ресурсів

Якщо інфраструктура більше не потрібна:

1. **(Опціонально) Приберіть застосунки через Argo CD UI** (наприклад, видалення Application `example-app`). Це необов'язково, якщо ви все одно робите `terraform destroy`, але так швидше прибрати ресурси додатку.

2. **Видаліть ECR-репозиторій з образами:**

```bash
aws ecr delete-repository --repository-name final-project-ecr --force --region eu-central-1
```

3. **Видаліть решту інфраструктури через Terraform:**

```bash
cd final-project
terraform destroy
```

4. **Особливості:**

- якщо в S3-бакеті залишилися файли стейту, видалення бакета може впасти з помилкою;
- у такому разі зайдіть у консоль S3, виконайте **Empty** для бакета, а потім видаліть його;
- якщо `terraform destroy` зупиняється на видаленні Aurora/RDS через final snapshot, видаліть snapshot в AWS (ідентифікатор: `<db-ім'я>-final-snapshot`, у вашому випадку `myapp-db-final-snapshot`) і запустіть `terraform destroy` ще раз.
- переконайтеся, що всі платні ресурси (VPC, ECR тощо) видалені, щоб уникнути зайвих нарахувань.
