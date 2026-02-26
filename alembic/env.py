# alembic/env.py
# Конфигурация Alembic для управления миграциями БД

import sys
import logging
from pathlib import Path

# Добавляем корень проекта в sys.path, чтобы импортировать пакет app
# Предполагается, что alembic/ находится в корне проекта
project_root = Path(__file__).resolve().parents[1]
if str(project_root) not in sys.path:
    sys.path.insert(0, str(project_root))

# Импортируем конфигурацию и модели один раз
from app.core.config import settings
from app.db.base import Base

# Импорт моделей, чтобы они были зарегистрированы в Base.metadata
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

from logging.config import fileConfig
from sqlalchemy import engine_from_config, pool
from alembic import context

# this is the Alembic Config object, which provides
# the values of the [alembic] section of the .ini
# file in use.
config = context.config

# Interpret the config file for Python logging.
# This line sets up loggers basically.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

logger = logging.getLogger('alembic.env')

# Устанавливаем DATABASE_URL из настроек приложения
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)

# Этот объект представляет метаданные SQLAlchemy
target_metadata = Base.metadata


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode.

    This configures the context with just a URL
    and not an Engine, though an Engine is acceptable
    here as well.  By skipping the Engine creation
    we don't even need a DBAPI to be available.

    Calls to context.execute() here emit the given string to the
    script output.

    """
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode.

    In this scenario we need to create an Engine
    and associate a connection with the context.

    """
    # Этот код проверяет конфигурацию из файла .ini.
    # По умолчанию используем конфигурацию из app.core.config
    configuration = config.get_section(config.config_ini_section)
    configuration["sqlalchemy.url"] = settings.DATABASE_URL

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection, target_metadata=target_metadata
        )

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    logger.info("Running migrations in OFFLINE mode")
    run_migrations_offline()
else:
    logger.info("Running migrations in ONLINE mode")
    run_migrations_online()