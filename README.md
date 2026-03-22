# ProjectPhoenix

Практичный workflow для нашей совместной работы:

1. Я меняю локальные файлы проекта в этом репозитории.
2. После изменений даю список файлов и команды проверки.
3. Ты делаешь `git add/commit/push`.
4. На сервере выполняешь `git pull origin master` и деплой.

## Важное разделение

- В GitHub коммитим только проектные файлы из репозитория.
- Не коммитим серверные секреты и системные файлы:
  - `/etc/nginx/...`
  - `/etc/systemd/...`
  - `server/.env` (если там реальные пароли/токены)

Для серверных правок я всегда даю отдельные команды, которые запускаются прямо на сервере по SSH.

## Быстрый деплой web версии

Подготовлено скриптом:
- `scripts/deploy_web.sh`

Запуск с Mac:

```bash
cd <путь_к_проекту>
./scripts/deploy_web.sh
```

Если сборка уже сделана заранее:

```bash
./scripts/deploy_web.sh --skip-build
```

Переменные (опционально):

```bash
SERVER=root@89.23.99.18 REMOTE_WEB_ROOT=/var/www/garphoenix.com ./scripts/deploy_web.sh
```

## Проверка production

Скрипт проверки:
- `scripts/prod_health_check.sh`

```bash
cd <путь_к_проекту>
./scripts/prod_health_check.sh
```

или для другого домена:

```bash
./scripts/prod_health_check.sh garphoenix.com
```

## PostgreSQL на сервере (Timeweb)

Не храните реальные пароли в Git-репозитории.

Рекомендуемый формат `DATABASE_URL` для `server/.env`:

```env
DATABASE_URL=postgresql://<db_user>:<db_password>@127.0.0.1:5432/projectphoenix
```

Создание пользователя и БД на сервере:

```bash
DB_USER="<db_user>"
DB_PASS="<db_password>"
DB_NAME="projectphoenix"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${DB_USER}', '${DB_PASS}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${DB_USER}', '${DB_PASS}');
  END IF;
  EXECUTE format('ALTER ROLE %I CREATEDB', '${DB_USER}');
END
\$\$;
SQL

sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
```
