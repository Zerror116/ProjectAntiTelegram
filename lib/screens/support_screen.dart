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
  final TextEditingController _productSearchCtrl = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final FocusNode _productSearchFocusNode = FocusNode();

  bool _loading = false;
  bool _productSearchLoading = false;
  String _selectedCategory = 'general';
  Timer? _productSearchDebounce;
  Map<String, dynamic>? _selectedProduct;
  List<Map<String, dynamic>> _productResults = const [];
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
  }

  @override
  void dispose() {
    _productSearchDebounce?.cancel();
    _productSearchCtrl.removeListener(_handleProductSearchChanged);
    _controller.dispose();
    _productSearchCtrl.dispose();
    _inputFocusNode.dispose();
    _productSearchFocusNode.dispose();
    super.dispose();
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
        _productResults =
            data is Map && data['ok'] == true && data['data'] is List
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

  Future<void> _ask() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _loading = true;
      _messages.add({'from': 'user', 'text': text});
    });
    _controller.clear();

    try {
      final resp = await authService.dio.post(
        '/api/support/ask',
        data: {
          'message': text,
          'category': _selectedCategory,
          if (_selectedCategory == 'product' && _selectedProduct != null)
            'product_id': (_selectedProduct?['id'] ?? '').toString(),
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
          final settings = <String, dynamic>{
            'kind': 'support_ticket',
            'support_ticket': true,
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
              labelText: 'Товар из Основного канала',
              hintText: 'Введите название товара',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Поддержка')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final fromUser = msg['from'] == 'user';
                  final text = msg['text'] ?? '';
                  return Align(
                    alignment: fromUser
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: text.trim().isEmpty
                          ? null
                          : () => _copyText(text),
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
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: PhoenixLoadingView(
                  title: 'Поддержка отвечает',
                  subtitle: 'Формируем ответ',
                  size: 40,
                ),
              ),
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
                              'У меня вопрос по товару: ',
                            ),
                    ),
                    ActionChip(
                      label: const Text('Другой вопрос'),
                      onPressed: _loading
                          ? null
                          : () => _applyQuickTemplate(
                              'general',
                              'Здравствуйте, у меня вопрос: ',
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
                    _buildCategoryChip('general', 'Общий вопрос', Icons.chat_bubble_outline),
                    _buildCategoryChip('product', 'Товар', Icons.inventory_2_outlined),
                    _buildCategoryChip('delivery', 'Доставка', Icons.local_shipping_outlined),
                    _buildCategoryChip('cart', 'Корзина', Icons.shopping_cart_outlined),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _buildProductSearch(theme),
            ),
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
                            hintText: _selectedCategory == 'product'
                                ? 'Опишите, что именно не так с товаром...'
                                : 'Напишите вопрос...',
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
