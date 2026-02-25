# server/src/models/devices_tokens.py
import datetime
from sqlalchemy import String, DateTime
from sqlalchemy.orm import mapped_column, Session
from .db import AbstractModel, engine

class Devices(AbstractModel):
    __tablename__ = "devices"
    id = mapped_column(String, primary_key=True)
    user_id = mapped_column(String, nullable=True)
    device_fingerprint = mapped_column(String, nullable=True)
    last_seen = mapped_column(DateTime, default=datetime.datetime.utcnow)
    trusted = mapped_column(Boolean, default=True)
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)

class RefreshTokens(AbstractModel):
    __tablename__ = "refresh_tokens"
    id = mapped_column(String, primary_key=True)
    user_id = mapped_column(String, nullable=True)
    token = mapped_column(String, nullable=True)
    device_id = mapped_column(String, nullable=True)
    expires_at = mapped_column(DateTime, nullable=True)
    created_at = mapped_column(DateTime, default=datetime.datetime.utcnow)
