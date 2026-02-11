# app/db/base.py
# Общая declarative база для SQLAlchemy.
# Этот модуль должен быть максимально простым и не импортировать модели,
# чтобы избежать циклических импортов. Модели должны импортировать Base отсюда.

from sqlalchemy.orm import declarative_base

# Единственная точка определения Base для всех моделей
Base = declarative_base()
