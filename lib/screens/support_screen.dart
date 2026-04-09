import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../src/utils/media_url.dart';
import '../widgets/adaptive_network_image.dart';
import '../widgets/input_language_badge.dart';
import '../widgets/phoenix_loader.dart';
import '../widgets/submit_on_enter.dart';
import 'chat_screen.dart';

class SupportScreen extends StatefulWidget {
  final String? initialMessage;

  const SupportScreen({super.key, this.initialMessage});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final TextEditingController _controller = TextEditingController();
  final TextEditingController _detailsCtrl = TextEditingController();
  final TextEditingController _productSearchCtrl = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final FocusNode _detailsFocusNode = FocusNode();
  final FocusNode _productSearchFocusNode = FocusNode();

  bool _loading = false;
  bool _productSearchLoading = false;
  bool _faqLoading = false;
  String _selectedCategory = 'general';
  Timer? _productSearchDebounce;
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _productResults = const [];
  List<Map<String, dynamic>> _faqEntries = const [];
  final Set<String> _dismissedFaqIds = <String>{};
  final List<Map<String, String>> _messages = [];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialMessage?.trim();
    if (initial != null && initial.isNotEmpty) {
      _controller.text = initial;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
    }
    _productSearchCtrl.addListener(_handleProductSearchChanged);
    unawaited(_loadFaqEntries());
  }

  @override
  void dispose() {
    _productSearchDebounce?.cancel();
    _productSearchCtrl.removeListener(_handleProductSearchChanged);
    _controller.dispose();
    _detailsCtrl.dispose();
    _productSearchCtrl.dispose();
    _inputFocusNode.dispose();
    _detailsFocusNode.dispose();
    _productSearchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadFaqEntries() async {
    if (mounted) {
      setState(() => _faqLoading = true);
    } else {
      _faqLoading = true;
    }
    try {
      final resp = await authService.dio.get('/api/support/faq');
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        _faqEntries = data is Map && data['ok'] == true && data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : const <Map<String, dynamic>>[];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _faqEntries = const <Map<String, dynamic>>[]);
    } finally {
      if (mounted) {
        setState(() => _faqLoading = false);
      } else {
        _faqLoading = false;
      }
    }
  }

  Future<void> _copyText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: normalized));
    if (!mounted) return;
    showAppNotice(
      context,
      'Текст скопирован',
      tone: AppNoticeTone.success,
      duration: const Duration(milliseconds: 1000),
    );
  }

  void _setCategory(String value) {
    final next = value.trim().toLowerCase();
    if (_selectedCategory == next) return;
    setState(() {
      _selectedCategory = next;
      _dismissedFaqIds.clear();
      _detailsCtrl.clear();
      if (next != 'product') {
        _selectedProduct = null;
        _productResults = const [];
        _productSearchCtrl.clear();
      }
    });
  }

  void _applyQuickTemplate(
    String category,
    String value, {
    bool sendNow = false,
  }) {
    _setCategory(category);
    _controller.text = value;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    _inputFocusNode.requestFocus();
    if (sendNow) {
      _ask();
    }
  }

  void _handleProductSearchChanged() {
    if (_selectedCategory != 'product') return;
    _productSearchDebounce?.cancel();
    final query = _productSearchCtrl.text.trim();
    if (query.length < 2) {
      if (mounted) {
        setState(() {
          _productResults = const [];
          _productSearchLoading = false;
        });
      }
      return;
    }
    _productSearchDebounce = Timer(const Duration(milliseconds: 280), () {
      unawaited(_searchProducts(query));
    });
  }

  Future<void> _searchProducts(String query) async {
    final normalized = query.trim();
    if (normalized.length < 2) return;
    if (mounted) {
      setState(() => _productSearchLoading = true);
    }
    try {
      final resp = await authService.dio.get(
        '/api/support/products/search',
        queryParameters: {'q': normalized},
      );
      final data = resp.data;
      if (!mounted) return;
      setState(() {
        _productResults = data is Map && data['ok'] == true && data['data'] is List
            ? List<Map<String, dynamic>>.from(data['data'])
            : <Map<String, dynamic>>[];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _productResults = const []);
    } finally {
      if (mounted) {
        setState(() => _productSearchLoading = false);
      } else {
        _productSearchLoading = false;
      }
    }
  }

  void _selectProduct(Map<String, dynamic> product) {
    setState(() {
      _selectedProduct = product;
      _productResults = const [];
      _productSearchCtrl.text = (product['title'] ?? '').toString();
      _productSearchCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _productSearchCtrl.text.length),
      );
    });
    _inputFocusNode.requestFocus();
  }

  String _formatMoney(dynamic value) {
    final number = num.tryParse('${value ?? ''}');
    if (number == null) return '0 ₽';
    return '${number.toStringAsFixed(number % 1 == 0 ? 0 : 2)} ₽';
  }

  String? _resolveImageUrl(String? raw) {
    return resolveMediaUrl(raw, apiBaseUrl: authService.dio.options.baseUrl);
  }

  String _categoryLabel(String category) {
    switch (category.trim().toLowerCase()) {
      case 'product':
        return 'Товар';
      case 'delivery':
        return 'Доставка';
      case 'cart':
        return 'Корзина';
      default:
        return 'Общий вопрос';
    }
  }

  String _questionLabel() {
    switch (_selectedCategory) {
      case 'product':
        return 'Что не так с товаром?';
      case 'delivery':
        return 'Что случилось с доставкой?';
      case 'cart':
        return 'Что случилось с корзиной?';
      default:
        return 'Ваш вопрос';
    }
  }

  String _questionHint() {
    switch (_selectedCategory) {
      case 'product':
        return 'Опиши проблему с товаром понятными словами';
      case 'delivery':
        return 'Например: курьер не приехал, неверный адрес, не дозвонились';
      case 'cart':
        return 'Например: не сходится сумма, ошибка оплаты, отказ от товара';
      default:
        return 'Напишите, чем помочь';
    }
  }

  String? _detailsLabel() {
    switch (_selectedCategory) {
      case 'delivery':
        return 'Уточнение по доставке';
      case 'cart':
        return 'Уточнение по корзине';
      default:
        return null;
    }
  }

  String? _detailsHint() {
    switch (_selectedCategory) {
      case 'delivery':
        return 'Адрес, ориентир, удобное время или другая важная деталь';
      case 'cart':
        return 'Сумма, оплата, отказ, возврат или другая деталь';
      default:
        return null;
    }
  }

  Iterable<Map<String, dynamic>> _faqEntriesForCurrentCategory() {
    final current = _selectedCategory.trim().toLowerCase();
    return _faqEntries.where((entry) {
      final id = (entry['id'] ?? '').toString().trim();
      if (id.isNotEmpty && _dismissedFaqIds.contains(id)) return false;
      final category = (entry['category'] ?? 'general').toString().trim().toLowerCase();
      if (current == 'general') {
        return category == 'general';
      }
      return category == current || category == 'general';
    });
  }

  bool _faqMatchesQuery(Map<String, dynamic> entry, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return true;
    final question = (entry['question'] ?? '').toString().toLowerCase();
    final answer = (entry['answer'] ?? '').toString().toLowerCase();
    final keywords = (entry['keywords'] ?? '').toString().toLowerCase();
    return question.contains(normalizedQuery) ||
        answer.contains(normalizedQuery) ||
        keywords.contains(normalizedQuery);
  }

  List<Map<String, dynamic>> _suggestedFaqEntries() {
    final query = _controller.text.trim();
    if (query.length < 2) return const <Map<String, dynamic>>[];
    return _faqEntriesForCurrentCategory()
        .where((entry) => _faqMatchesQuery(entry, query))
        .take(3)
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _topFaqEntries() {
    return _faqEntriesForCurrentCategory()
        .take(4)
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  void _markFaqHelpful(Map<String, dynamic> entry) {
    final id = (entry['id'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      setState(() => _dismissedFaqIds.add(id));
    }
    setState(() {
      _messages.add({
        'from': 'bot',
        'text': 'Отлично. Если вопрос останется, вы всегда можете написать в поддержку.',
      });
    });
    showAppNotice(
      context,
      'Рады, что это помогло',
      tone: AppNoticeTone.success,
    );
  }

  void _continueWithFaq(Map<String, dynamic> entry) {
    final id = (entry['id'] ?? '').toString().trim();
    if (id.isNotEmpty) {
      setState(() => _dismissedFaqIds.add(id));
    }
    _inputFocusNode.requestFocus();
  }

  String _buildSupportRequestText() {
    final question = _controller.text.trim();
    final details = _detailsCtrl.text.trim();
    if (question.isEmpty) return '';

    final parts = <String>[];
    if (_selectedCategory == 'product' && _selectedProduct != null) {
      final productTitle = (_selectedProduct?['title'] ?? '').toString().trim();
      if (productTitle.isNotEmpty) {
        parts.add('Товар: $productTitle');
      }
    }
    parts.add('Вопрос: $question');
    if (details.isNotEmpty) {
      final detailsLabel = _detailsLabel() ?? 'Уточнение';
      parts.add('$detailsLabel: $details');
    }
    return parts.join('\n');
  }

  Future<void> _ask() async {
    final text = _controller.text.trim();
    final detailsText = _detailsCtrl.text.trim();
    final payloadText = _buildSupportRequestText();
    if (text.isEmpty || payloadText.isEmpty) return;
    if (_selectedCategory == 'product' && _selectedProduct == null) {
      showAppNotice(
        context,
        'Сначала выберите товар, по которому нужен ответ',
        tone: AppNoticeTone.warning,
      );
      _productSearchFocusNode.requestFocus();
      return;
    }

    final shownFaqIds = _suggestedFaqEntries()
        .map((entry) => (entry['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    setState(() {
      _loading = true;
      _messages.add({'from': 'user', 'text': payloadText});
    });
    _controller.clear();
    _detailsCtrl.clear();

    try {
      final resp = await authService.dio.post(
        '/api/support/ask',
        data: {
          'message': payloadText,
          'category': _selectedCategory,
          if (_selectedCategory == 'product' && _selectedProduct != null)
            'product_id': (_selectedProduct?['id'] ?? '').toString(),
          'details': {
            'question': text,
            'extra_context': detailsText,
            'faq_ids_shown': shownFaqIds,
          },
        },
      );
      final data = resp.data;
      String reply = 'Не удалось получить ответ';
      Map<String, dynamic> payload = const {};
      if (data is Map && data['ok'] == true && data['data'] is Map) {
        payload = Map<String, dynamic>.from(data['data']);
        reply = (payload['reply'] ?? reply).toString();
      }
      setState(() => _messages.add({'from': 'bot', 'text': reply}));
      await playAppSound(AppUiSound.success);

      final mode = (payload['mode'] ?? '').toString().trim().toLowerCase();
      if (mode == 'ticket') {
        final chatId = (payload['chat_id'] ?? '').toString().trim();
        if (chatId.isNotEmpty && mounted) {
          final chatTitle = (payload['chat_title'] ?? 'Поддержка').toString();
          final ticket = payload['ticket'];
          final supportTicketId = ticket is Map
              ? (ticket['id'] ?? '').toString().trim()
              : '';
          final status = ticket is Map
              ? (ticket['status'] ?? '').toString().trim()
              : '';
          final settings = <String, dynamic>{
            'kind': 'support_ticket',
            'support_ticket': true,
            if (status.isNotEmpty) 'support_ticket_status': status,
            if (supportTicketId.isNotEmpty)
              'support_ticket_id': supportTicketId,
          };
          await Future<void>.delayed(const Duration(milliseconds: 120));
          if (!mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                chatId: chatId,
                chatTitle: chatTitle,
                chatType: 'private',
                chatSettings: settings,
              ),
            ),
          );
        }
      }
    } catch (e) {
      setState(
        () => _messages.add({'from': 'bot', 'text': 'Ошибка поддержки: $e'}),
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      } else {
        _loading = false;
      }
    }
  }

  Widget _buildCategoryChip(String value, String label, IconData icon) {
    final selected = _selectedCategory == value;
    return ChoiceChip(
      selected: selected,
      onSelected: _loading ? null : (_) => _setCategory(value),
      avatar: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  Widget _buildSelectedProductCard(ThemeData theme) {
    final product = _selectedProduct;
    if (product == null) return const SizedBox.shrink();
    final imageUrl = _resolveImageUrl((product['image_url'] ?? '').toString());
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 46,
            height: 46,
            child: imageUrl == null
                ? Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const Icon(Icons.inventory_2_outlined),
                  )
                : AdaptiveNetworkImage(
                    imageUrl,
                    fit: BoxFit.cover,
                  ),
          ),
        ),
        title: Text(
          (product['title'] ?? 'Товар').toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _formatMoney(product['price']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          onPressed: _loading
              ? null
              : () {
                  setState(() {
                    _selectedProduct = null;
                    _productSearchCtrl.clear();
                    _productResults = const [];
                  });
                  _productSearchFocusNode.requestFocus();
                },
          icon: const Icon(Icons.close),
          tooltip: 'Убрать товар',
        ),
      ),
    );
  }

  Widget _buildProductSearch(ThemeData theme) {
    if (_selectedCategory != 'product') return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSelectedProductCard(theme),
        TextField(
          focusNode: _productSearchFocusNode,
          controller: _productSearchCtrl,
          enabled: !_loading,
          decoration: withInputLanguageBadge(
            InputDecoration(
              labelText: 'Выберите товар',
              hintText: 'Введите название товара из основного канала',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _productSearchLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            controller: _productSearchCtrl,
          ),
        ),
        if (_productResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: _productResults.map((product) {
                final title = (product['title'] ?? 'Товар').toString();
                final code = (product['product_code'] ?? '').toString().trim();
                final imageUrl =
                    _resolveImageUrl((product['image_url'] ?? '').toString());
                return ListTile(
                  onTap: _loading ? null : () => _selectProduct(product),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: imageUrl == null
                          ? Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: const Icon(Icons.inventory_2_outlined),
                            )
                          : AdaptiveNetworkImage(
                              imageUrl,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (code.isNotEmpty) 'ID: $code',
                      _formatMoney(product['price']),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildConversationArea(ThemeData theme) {
    if (_messages.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Поддержка',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Сначала посмотрите частые вопросы ниже. Если ответ не подошёл, напишите нам — обращение уйдёт в отдельный чат поддержки.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final fromUser = msg['from'] == 'user';
        final text = msg['text'] ?? '';
        return Align(
          alignment:
              fromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: text.trim().isEmpty ? null : () => _copyText(text),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: fromUser
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: fromUser
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFaqCard(ThemeData theme, Map<String, dynamic> entry) {
    final question = (entry['question'] ?? 'Вопрос').toString().trim();
    final answer = (entry['answer'] ?? '').toString().trim();
    final category = _categoryLabel((entry['category'] ?? '').toString());
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  category,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            question,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (answer.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              answer,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _loading ? null : () => _markFaqHelpful(entry),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Это помогло'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : () => _continueWithFaq(entry),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Всё равно написать'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFaqSection(ThemeData theme) {
    final suggestedEntries = _suggestedFaqEntries();
    final topEntries = suggestedEntries.isNotEmpty
        ? suggestedEntries
        : _topFaqEntries();
    if (_faqLoading && _faqEntries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (topEntries.isEmpty) return const SizedBox.shrink();

    final title = suggestedEntries.isNotEmpty
        ? 'Похоже, это может помочь'
        : 'Частые вопросы';
    final subtitle = suggestedEntries.isNotEmpty
        ? 'Проверьте короткие ответы перед созданием обращения.'
        : 'Сначала попробуйте быстрые ответы по теме.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          ...topEntries.map((entry) => _buildFaqCard(theme, entry)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailsLabel = _detailsLabel();
    final detailsHint = _detailsHint();

    return Scaffold(
      appBar: AppBar(title: const Text('Поддержка')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildConversationArea(theme)),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: PhoenixLoadingView(
                  title: 'Поддержка отвечает',
                  subtitle: 'Формируем ответ',
                  size: 40,
                ),
              ),
            _buildFaqSection(theme),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      label: const Text('Сумма корзины'),
                      onPressed: _loading
                          ? null
                          : () => _applyQuickTemplate(
                              'cart',
                              'Подскажите, какая у меня сумма корзины?',
                              sendNow: true,
                            ),
                    ),
                    ActionChip(
                      label: const Text('Доставка'),
                      onPressed: _loading
                          ? null
                          : () => _applyQuickTemplate(
                              'delivery',
                              'Подскажите, пожалуйста, что у меня по доставке?',
                            ),
                    ),
                    ActionChip(
                      label: const Text('Вопрос по товару'),
                      onPressed: _loading
                          ? null
                          : () => _applyQuickTemplate(
                              'product',
                              'У меня вопрос по товару:',
                            ),
                    ),
                    ActionChip(
                      label: const Text('Другой вопрос'),
                      onPressed: _loading
                          ? null
                          : () => _applyQuickTemplate(
                              'general',
                              'Здравствуйте, у меня вопрос:',
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildCategoryChip(
                      'general',
                      'Общий вопрос',
                      Icons.chat_bubble_outline,
                    ),
                    _buildCategoryChip(
                      'product',
                      'Товар',
                      Icons.inventory_2_outlined,
                    ),
                    _buildCategoryChip(
                      'delivery',
                      'Доставка',
                      Icons.local_shipping_outlined,
                    ),
                    _buildCategoryChip(
                      'cart',
                      'Корзина',
                      Icons.shopping_cart_outlined,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildProductSearch(theme),
            ),
            if (detailsLabel != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  focusNode: _detailsFocusNode,
                  controller: _detailsCtrl,
                  enabled: !_loading,
                  minLines: 1,
                  maxLines: 3,
                  decoration: withInputLanguageBadge(
                    InputDecoration(
                      labelText: detailsLabel,
                      hintText: detailsHint,
                      border: const OutlineInputBorder(),
                    ),
                    controller: _detailsCtrl,
                  ),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: SubmitOnEnter(
                      controller: _controller,
                      enabled: !_loading,
                      onSubmit: _ask,
                      child: TextField(
                        focusNode: _inputFocusNode,
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: withInputLanguageBadge(
                          InputDecoration(
                            labelText: _questionLabel(),
                            hintText: _questionHint(),
                            border: const OutlineInputBorder(),
                          ),
                          controller: _controller,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _loading ? null : _ask,
                    icon: const Icon(Icons.send),
                    tooltip: 'Отправить в поддержку',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
