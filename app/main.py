# app/main.py
# Точка входа FastAPI. Создание таблиц выполняется в событии startup с обработкой ошибок.

from fastapi import FastAPI
import time
import logging

from app.db.session import engine
from app.db.base import Base

# Импорт моделей, чтобы SQLAlchemy видел их определения
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

logger = logging.getLogger(__name__)

app = FastAPI(title="Тапка")

def try_create_tables(retries: int = 5, delay: int = 2):
    """
    Пытаемся создать таблицы с повторными попытками.
    Если БД недоступна, логируем ошибку и пробуем снова.
    """
    for attempt in range(1, retries + 1):
        try:
            Base.metadata.create_all(bind=engine)
            logger.info("Database tables created (or already exist).")
            return True
        except Exception as e:
            logger.warning(f"Attempt {attempt}/{retries} failed to create tables: {e}")
            if attempt < retries:
                time.sleep(delay)
            else:
                logger.error("Could not create tables after retries. Continuing without DB schema creation.")
                return False

@app.on_event("startup")
def on_startup():
    # При старте пробуем создать таблицы; если не получилось — приложение всё равно стартует.
    try_create_tables(retries=5, delay=2)

# Подключаем роутеры
from app.api import auth as auth_router  # убедитесь, что app/api/__init__.py импортирует нужные модули
app.include_router(auth_router.router, prefix="/api/auth", tags=["auth"])
