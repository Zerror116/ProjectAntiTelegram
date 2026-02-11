# app/models/order.py
# Модели Order и OrderItem для фиксации сумм и статусов заказа.
from sqlalchemy import Column, Integer, ForeignKey, Float, DateTime, Enum
from sqlalchemy.orm import relationship
from datetime import datetime
from app.db.base import Base
import enum

class OrderStatus(str, enum.Enum):
    reserved = "reserved"
    processing = "processing"
    processed = "processed"
    handed_to_courier = "handed_to_courier"
    in_delivery = "in_delivery"
    delivered = "delivered"
    cancelled = "cancelled"

class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    total = Column(Float, default=0.0)
    status = Column(Enum(OrderStatus), default=OrderStatus.reserved)
    created_at = Column(DateTime, default=datetime.utcnow)

    user = relationship("User")
    items = relationship("OrderItem", back_populates="order")

class OrderItem(Base):
    __tablename__ = "order_items"

    id = Column(Integer, primary_key=True, index=True)
    order_id = Column(Integer, ForeignKey("orders.id"), nullable=False)
    draft_id = Column(Integer, ForeignKey("product_drafts.id"), nullable=False)
    quantity = Column(Integer, default=1)
    price = Column(Float, nullable=False)

    order = relationship("Order", back_populates="items")
    draft = relationship("ProductDraft")
