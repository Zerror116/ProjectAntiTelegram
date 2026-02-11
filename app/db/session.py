# app/db/session.py
# Инициализация SQLAlchemy engine и фабрики сессий.
# Поддерживает как Postgres, так и SQLite (для тестов/локального использования).

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from app.core.config import settings

DATABASE_URL = settings.DATABASE_URL

# Для sqlite требуется connect_args; для Postgres — пустой dict
connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}

# pool_pre_ping полезен для долгоживущих соединений с Postgres
engine = create_engine(
    DATABASE_URL,
    connect_args=connect_args,
    pool_pre_ping=True
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
