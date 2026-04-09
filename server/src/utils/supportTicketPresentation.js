function normalizeSupportTicketStatus(raw) {
  const normalized = String(raw || '').trim().toLowerCase();
  if (['open', 'waiting_customer', 'resolved', 'archived'].includes(normalized)) {
    return normalized;
  }
  return 'open';
}

function hasAssigneeValue(raw) {
  return String(raw || '').trim().length > 0;
}

function buildSupportTicketStatusLabel(statusRaw, { assigneeId = null } = {}) {
  const status = normalizeSupportTicketStatus(statusRaw);
  switch (status) {
    case 'waiting_customer':
      return 'Ждём ваш ответ';
    case 'resolved':
      return 'Решено';
    case 'archived':
      return 'Закрыто';
    case 'open':
    default:
      return hasAssigneeValue(assigneeId) ? 'В работе' : 'Новая заявка';
  }
}

function buildSupportTicketStatusHint(statusRaw, { assigneeId = null } = {}) {
  const status = normalizeSupportTicketStatus(statusRaw);
  switch (status) {
    case 'waiting_customer':
      return 'Сейчас ждём ваш ответ';
    case 'resolved':
      return 'Подтвердите решение или верните обращение в работу';
    case 'archived':
      return 'Обращение закрыто';
    case 'open':
    default:
      return hasAssigneeValue(assigneeId)
        ? 'Сейчас ход за поддержкой'
        : 'Ожидает сотрудника поддержки';
  }
}

function decorateSupportTicketRow(row) {
  if (!row || typeof row !== 'object') return row;
  const assigneeId = row.assignee_id || null;
  const status = normalizeSupportTicketStatus(row.status);
  return {
    ...row,
    status,
    status_display: buildSupportTicketStatusLabel(status, { assigneeId }),
    status_hint: buildSupportTicketStatusHint(status, { assigneeId }),
    can_customer_confirm_resolution: status === 'resolved',
    support_waiting_customer: status === 'waiting_customer',
  };
}

module.exports = {
  normalizeSupportTicketStatus,
  buildSupportTicketStatusLabel,
  buildSupportTicketStatusHint,
  decorateSupportTicketRow,
};
