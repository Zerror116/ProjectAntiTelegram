# app/main.py
# Точка входа FastAPI. Подключаем роутеры и при необходимости создаём таблицы (dev only).

from fastapi import FastAPI
from app.core.config import settings
from app.db.session import engine
from app.db.base import Base

# Импорт моделей, чтобы Base.metadata.create_all видел все таблицы
# (импорты моделей должны быть корректными)
import app.models.user
import app.models.product
import app.models.cart
import app.models.order

app = FastAPI(title="AntiTelegram")

# В режиме разработки можно автоматически создавать таблицы.
# В продакшне используйте alembic миграции.
Base.metadata.create_all(bind=engine)

# Здесь подключайте ваши routers, например:
# from app.api import auth, products, admin, cart, channel
# app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
