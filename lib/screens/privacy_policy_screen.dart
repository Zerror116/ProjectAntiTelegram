import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Политика конфиденциальности')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Важно',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.colorScheme.error.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                'Этот раздел ещё будет обновлён. Пока соблюдайте приятное общение, без матов, желательно. '
                'Если что-то работает не так или сломается, откройте в приложении меню "Настройки" и нажмите "Сообщить о проблеме".',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Что хранится',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '1. Данные аккаунта: email, имя, телефон.\n'
              '2. Служебные данные: роли, группы арендаторов, активные сессии.\n'
              '3. Рабочие данные: посты товаров, заказы, статусы корзины и доставки.\n'
              '4. Переписка в чатах и обращения в поддержку.',
            ),
            const SizedBox(height: 14),
            Text(
              'Кто видит данные',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '1. Клиент видит только свои данные и доступные ему чаты.\n'
              '2. Работник/админ видят только данные своей группы арендатора.\n'
              '3. Создатель платформы управляет ключами и подписками арендаторов.',
            ),
            const SizedBox(height: 14),
            Text(
              'Безопасность',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '1. Используйте сложные пароли и не передавайте доступ третьим лицам.\n'
              '2. Выходите из аккаунта на чужих устройствах.\n'
              '3. При подозрительной активности обратитесь в поддержку.',
            ),
          ],
        ),
      ),
    );
  }
}
