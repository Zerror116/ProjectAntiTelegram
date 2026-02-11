# alembic/env.py
import sys
from pathlib import Path

# Добавляем корень проекта в sys.path, чтобы импортировать пакет app
# Предполагается, что alembic/ находится в корне проекта
project_root = Path(__file__).resolve().parents[1]
if str(project_root) not in sys.path:
    sys.path.insert(0, str(project_root))

# Теперь можно импортировать app.*
from app.core.config import settings
from app.db.base import Base
# далее ваш существующий код...

from logging.config import fileConfig
from sqlalchemy import engine_from_config, pool
from alembic import context

# импортируем настройки проекта
from app.core.config import settings
from app.db.base import Base

# импорт моделей, чтобы они были зарегистрированы в Base
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

config = context.config

# Подставляем URL из настроек приложения
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)

# Настройка логирования
fileConfig(config.config_file_name)

# metadata для автогенерации
target_metadata = Base.metadata

def run_migrations_online():
    connectable = engine_from_config(
        config.get_section(config.config_ini_section),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)

        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    # Оставляем стандартную offline реализацию (если нужна)
    context.configure(url=settings.DATABASE_URL, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    run_migrations_online()
