# app/db/base.py
# Общая declarative база для SQLAlchemy.
# Модели импортируют Base из этого модуля.

from sqlalchemy.orm import declarative_base

Base = declarative_base()
