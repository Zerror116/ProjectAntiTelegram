import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../main.dart';
import 'input_language_badge.dart';

const String _defaultAddressMapTiles =
    'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
const String _addressMapTileUrl = String.fromEnvironment(
  'FENIX_MAP_TILE_LIGHT',
  defaultValue: _defaultAddressMapTiles,
);
const String _addressMapSubdomainsRaw = String.fromEnvironment(
  'FENIX_MAP_TILE_SUBDOMAINS',
  defaultValue: 'a,b,c,d',
);
const String _addressMapAttribution = String.fromEnvironment(
  'FENIX_MAP_ATTRIBUTION',
  defaultValue: '© OpenStreetMap contributors © CARTO',
);

class DeliveryAddressPickerDialog extends StatefulWidget {
  const DeliveryAddressPickerDialog({
    super.key,
    required this.title,
    this.initialAddressText = '',
    this.initialEntrance = '',
    this.initialComment = '',
    this.initialPreferredTimeFrom = '',
    this.initialPreferredTimeTo = '',
    this.showTimeWindow = true,
    this.allowSaveAsDefault = true,
  });

  final String title;
  final String initialAddressText;
  final String initialEntrance;
  final String initialComment;
  final String initialPreferredTimeFrom;
  final String initialPreferredTimeTo;
  final bool showTimeWindow;
  final bool allowSaveAsDefault;

  @override
  State<DeliveryAddressPickerDialog> createState() =>
      _DeliveryAddressPickerDialogState();
}

class _DeliveryAddressPickerDialogState
    extends State<DeliveryAddressPickerDialog> {
  static const LatLng _defaultCenter = LatLng(55.751244, 37.618423);

  final TextEditingController _addressCtrl = TextEditingController();
  final TextEditingController _entranceCtrl = TextEditingController();
  final TextEditingController _commentCtrl = TextEditingController();
  final TextEditingController _afterCtrl = TextEditingController();
  final TextEditingController _beforeCtrl = TextEditingController();
  final MapController _mapController = MapController();

  Timer? _debounce;
  List<Map<String, dynamic>> _suggestions = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _savedAddresses = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _zones = <Map<String, dynamic>>[];
  bool _loadingSuggestions = false;
  bool _loadingSavedAddresses = false;
  bool _loadingZones = false;
  bool _reversingPoint = false;
  bool _submitting = false;
  bool _confirmSelection = false;
  bool _saveAsDefault = true;
  String _validationMessage = '';
  double? _selectedLat;
  double? _selectedLng;
  Map<String, dynamic>? _selectedProviderData;

  @override
  void initState() {
    super.initState();
    _addressCtrl.text = widget.initialAddressText;
    _entranceCtrl.text = widget.initialEntrance;
    _commentCtrl.text = widget.initialComment;
    _afterCtrl.text = widget.initialPreferredTimeFrom;
    _beforeCtrl.text = widget.initialPreferredTimeTo;
    _saveAsDefault = widget.allowSaveAsDefault;
    _addressCtrl.addListener(_scheduleSuggestionsLoad);
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _addressCtrl.removeListener(_scheduleSuggestionsLoad);
    _addressCtrl.dispose();
    _entranceCtrl.dispose();
    _commentCtrl.dispose();
    _afterCtrl.dispose();
    _beforeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    await Future.wait<void>([
      _loadSavedAddresses(),
      _loadZones(),
    ]);
    if (_addressCtrl.text.trim().length >= 3) {
      await _loadSuggestions(_addressCtrl.text.trim(), immediate: true);
    }
  }

  List<String> _subdomains() {
    return _addressMapSubdomainsRaw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  Future<void> _loadSavedAddresses() async {
    setState(() => _loadingSavedAddresses = true);
    try {
      final resp = await authService.dio.get('/api/delivery/addresses');
      final data = resp.data;
      final items = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() => _savedAddresses = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _savedAddresses = <Map<String, dynamic>>[]);
    } finally {
      if (mounted) {
        setState(() => _loadingSavedAddresses = false);
      }
    }
  }

  Future<void> _loadZones() async {
    setState(() => _loadingZones = true);
    try {
      final resp = await authService.dio.get('/api/delivery/zones');
      final data = resp.data;
      final items = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() => _zones = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _zones = <Map<String, dynamic>>[]);
    } finally {
      if (mounted) {
        setState(() => _loadingZones = false);
      }
    }
  }

  void _scheduleSuggestionsLoad() {
    _confirmSelection = false;
    _validationMessage = '';
    _debounce?.cancel();
    final query = _addressCtrl.text.trim();
    if (query.length < 3) {
      setState(() {
        _suggestions = <Map<String, dynamic>>[];
        _loadingSuggestions = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 280),
      () => unawaited(_loadSuggestions(query)),
    );
  }

  Future<void> _loadSuggestions(String query, {bool immediate = false}) async {
    if (!mounted) return;
    setState(() => _loadingSuggestions = true);
    try {
      final resp = await authService.dio.get(
        '/api/delivery/address/suggest',
        queryParameters: {
          'q': query,
          'limit': 6,
          if (_selectedLat != null) 'lat': _selectedLat,
          if (_selectedLng != null) 'lng': _selectedLng,
        },
      );
      final data = resp.data;
      final items = data is Map && data['ok'] == true && data['data'] is List
          ? List<Map<String, dynamic>>.from(data['data'])
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _suggestions = items;
        if (items.isNotEmpty) {
          _validationMessage = '';
        }
      });
    } on DioException catch (e) {
      final body = e.response?.data;
      final message = body is Map
          ? (body['error'] ?? '').toString().trim()
          : '';
      if (!mounted) return;
      setState(() {
        _suggestions = <Map<String, dynamic>>[];
        if (message.isNotEmpty) {
          _validationMessage = message;
          _confirmSelection = false;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _suggestions = <Map<String, dynamic>>[]);
    } finally {
      if (mounted) {
        setState(() => _loadingSuggestions = false);
      }
    }
    if (immediate && mounted) {
      setState(() {});
    }
  }

  Future<void> _reverseSelectedPoint() async {
    if (_selectedLat == null || _selectedLng == null) return;
    setState(() {
      _reversingPoint = true;
      _validationMessage = '';
      _confirmSelection = false;
    });
    try {
      final resp = await authService.dio.post(
        '/api/delivery/address/reverse',
        data: {
          'lat': _selectedLat,
          'lng': _selectedLng,
        },
      );
      final data = resp.data;
      final payload = data is Map && data['ok'] == true && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      if (!mounted || payload.isEmpty) return;
      _applyAddressSelection(payload, moveMap: false, updateTextOnly: true);
    } on DioException catch (e) {
      final body = e.response?.data;
      final message = body is Map
          ? (body['error'] ?? '').toString().trim()
          : '';
      if (!mounted) return;
      setState(() {
        _validationMessage = message.isNotEmpty
            ? message
            : 'Не удалось распознать точку. Попробуй чуть точнее отметить вход на карте.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _validationMessage =
            'Не удалось распознать точку. Попробуй чуть точнее отметить вход на карте.';
      });
    } finally {
      if (mounted) {
        setState(() => _reversingPoint = false);
      }
    }
  }

  void _applyAddressSelection(
    Map<String, dynamic> data, {
    bool moveMap = true,
    bool updateTextOnly = false,
  }) {
    final lat = (data['lat'] is num) ? (data['lat'] as num).toDouble() : null;
    final lng = (data['lng'] is num) ? (data['lng'] as num).toDouble() : null;
    final addressText = (data['address_text'] ?? data['label'] ?? '')
        .toString()
        .trim();
    setState(() {
      if (addressText.isNotEmpty) {
        _addressCtrl.text = addressText;
        _addressCtrl.selection = TextSelection.collapsed(
          offset: _addressCtrl.text.length,
        );
      }
      _selectedLat = lat ?? _selectedLat;
      _selectedLng = lng ?? _selectedLng;
      _selectedProviderData = {
        ...?_selectedProviderData,
        ...data,
      };
      _suggestions = <Map<String, dynamic>>[];
      _validationMessage = '';
      _confirmSelection = false;
    });
    if (!updateTextOnly && moveMap && lat != null && lng != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.move(LatLng(lat, lng), 17);
      });
    }
  }

  Future<void> _submit() async {
    final addressText = _addressCtrl.text.trim();
    if (addressText.isEmpty && (_selectedLat == null || _selectedLng == null)) {
      setState(() {
        _validationMessage = 'Выбери адрес из подсказок или отметь точку на карте.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _validationMessage = '';
    });
    try {
      final resp = await authService.dio.post(
        '/api/delivery/address/validate',
        data: {
          'address_text': addressText,
          'lat': _selectedLat,
          'lng': _selectedLng,
          'provider': _selectedProviderData?['provider'],
          'provider_address_id': _selectedProviderData?['provider_address_id'],
          'address_structured': _selectedProviderData?['address_structured'],
          'entrance': _entranceCtrl.text.trim(),
          'comment': _commentCtrl.text.trim(),
          'confirm_selection': _confirmSelection,
        },
      );
      final data = resp.data;
      final payload = data is Map && data['ok'] == true && data['data'] is Map
          ? Map<String, dynamic>.from(data['data'])
          : <String, dynamic>{};
      if (!mounted || payload.isEmpty) return;
      Navigator.of(context).pop({
        ...payload,
        'entrance': _entranceCtrl.text.trim(),
        'comment': _commentCtrl.text.trim(),
        if (widget.showTimeWindow)
          'preferred_time_from': _afterCtrl.text.trim(),
        if (widget.showTimeWindow) 'preferred_time_to': _beforeCtrl.text.trim(),
        if (widget.allowSaveAsDefault) 'save_as_default': _saveAsDefault,
        'confirm_selection': _confirmSelection,
      });
    } on DioException catch (e) {
      final body = e.response?.data;
      final payload = body is Map && body['data'] is Map
          ? Map<String, dynamic>.from(body['data'])
          : <String, dynamic>{};
      final action = (payload['action'] ?? '').toString().trim();
      final summary = (payload['summary'] ?? body?['error'] ?? '')
          .toString()
          .trim();
      if (!mounted) return;
      setState(() {
        _validationMessage = summary.isNotEmpty
            ? summary
            : 'Не удалось проверить адрес. Попробуй ещё раз.';
        _confirmSelection = action == 'confirm';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _validationMessage = 'Не удалось проверить адрес. Попробуй ещё раз.';
      });
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  LatLng _currentCenter() {
    if (_selectedLat != null && _selectedLng != null) {
      return LatLng(_selectedLat!, _selectedLng!);
    }
    if (_savedAddresses.isNotEmpty) {
      final first = _savedAddresses.firstWhere(
        (item) =>
            item['lat'] is num &&
            item['lng'] is num &&
            (item['lat'] as num).toDouble() != 0 &&
            (item['lng'] as num).toDouble() != 0,
        orElse: () => <String, dynamic>{},
      );
      if (first['lat'] is num && first['lng'] is num) {
        return LatLng(
          (first['lat'] as num).toDouble(),
          (first['lng'] as num).toDouble(),
        );
      }
    }
    if (_zones.isNotEmpty) {
      final zone = _zones.first;
      final center = zone['center'] is Map
          ? Map<String, dynamic>.from(zone['center'])
          : <String, dynamic>{};
      final lat = center['lat'];
      final lng = center['lng'];
      if (lat is num && lng is num) {
        return LatLng(lat.toDouble(), lng.toDouble());
      }
    }
    return _defaultCenter;
  }

  List<CircleMarker> _buildZoneCircles() {
    return _zones.map((zone) {
      final center = zone['center'] is Map
          ? Map<String, dynamic>.from(zone['center'])
          : <String, dynamic>{};
      final lat = center['lat'];
      final lng = center['lng'];
      final radius = zone['radius_meters'];
      if (lat is! num || lng is! num || radius is! num) {
        return null;
      }
      return CircleMarker(
        point: LatLng(lat.toDouble(), lng.toDouble()),
        radius: radius.toDouble(),
        useRadiusInMeter: true,
        color: Colors.green.withValues(alpha: 0.12),
        borderColor: Colors.green.withValues(alpha: 0.55),
        borderStrokeWidth: 2,
      );
    }).whereType<CircleMarker>().toList();
  }

  Widget _buildSavedAddresses() {
    if (_loadingSavedAddresses) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    if (_savedAddresses.isEmpty) {
      return Text(
        'Сохранённых адресов пока нет. После первого подтверждения они появятся здесь.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _savedAddresses.map((item) {
        final title = (item['label'] ?? 'Адрес').toString().trim();
        final subtitle = (item['address_text'] ?? '').toString().trim();
        final entrance = (item['entrance'] ?? '').toString().trim();
        return ActionChip(
          avatar: Icon(
            item['is_default'] == true
                ? Icons.home_filled
                : Icons.location_on_outlined,
            size: 18,
          ),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              entrance.isNotEmpty ? '$title: $entrance' : (subtitle.isNotEmpty ? subtitle : title),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          onPressed: () {
            _entranceCtrl.text = entrance;
            _commentCtrl.text = (item['comment'] ?? '').toString();
            _applyAddressSelection(item, moveMap: true);
          },
        );
      }).toList(),
    );
  }

  Widget _buildSuggestions() {
    if (_loadingSuggestions) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_suggestions.isEmpty || _addressCtrl.text.trim().length < 3) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: _suggestions.map((item) {
          final label = (item['label'] ?? item['address_text'] ?? 'Адрес')
              .toString()
              .trim();
          final street = (item['address_structured'] is Map
                  ? Map<String, dynamic>.from(item['address_structured'])
                  : <String, dynamic>{})['street']
              ?.toString()
              .trim();
          return ListTile(
            dense: true,
            leading: const Icon(Icons.location_searching_outlined),
            title: Text(label),
            subtitle: street == null || street.isEmpty ? null : Text(street),
            onTap: () => _applyAddressSelection(item, moveMap: true),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedPoint =
        _selectedLat != null && _selectedLng != null
            ? LatLng(_selectedLat!, _selectedLng!)
            : null;
    final markers = <Marker>[
      if (selectedPoint != null)
        Marker(
          point: selectedPoint,
          width: 54,
          height: 54,
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 16,
                  color: Colors.black26,
                ),
              ],
            ),
            child: const Icon(Icons.place, color: Colors.white),
          ),
        ),
    ];

    final circles = _buildZoneCircles();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '1. Начни вводить адрес или выбери точку на карте.\n'
                '2. Если нужно, перетащи точку ближе к подъезду или ориентиру.\n'
                '3. В поле ниже можно указать "Магнит", "автомагазин", "у торца" и другие ориентиры.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                autofocus: true,
                minLines: 2,
                maxLines: 3,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Адрес доставки',
                    hintText: 'Россия, улица, дом',
                    border: OutlineInputBorder(),
                  ),
                  controller: _addressCtrl,
                ),
              ),
              _buildSuggestions(),
              const SizedBox(height: 12),
              Text(
                'Сохранённые адреса',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              _buildSavedAddresses(),
              const SizedBox(height: 12),
              Container(
                height: 300,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentCenter(),
                    initialZoom: selectedPoint == null ? 5.8 : 17,
                    onTap: (_, point) {
                      setState(() {
                        _selectedLat = point.latitude;
                        _selectedLng = point.longitude;
                        _selectedProviderData = {
                          ...?_selectedProviderData,
                          'lat': point.latitude,
                          'lng': point.longitude,
                          'point_source': 'map',
                        };
                      });
                      unawaited(_reverseSelectedPoint());
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _addressMapTileUrl,
                      subdomains: _subdomains(),
                      userAgentPackageName: 'projectphoenix',
                    ),
                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution(
                          _addressMapAttribution,
                          textStyle: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (circles.isNotEmpty) CircleLayer(circles: circles),
                    MarkerLayer(markers: markers),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _reversingPoint
                          ? 'Распознаём точку на карте...'
                          : 'Нажми на карту, чтобы отметить точный вход или ориентир.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (_loadingZones)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _entranceCtrl,
                minLines: 1,
                maxLines: 2,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Подъезд / ориентир',
                    hintText: 'Например: 2 подъезд, Магнит, у торца дома',
                    border: OutlineInputBorder(),
                  ),
                  controller: _entranceCtrl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _commentCtrl,
                minLines: 1,
                maxLines: 3,
                decoration: withInputLanguageBadge(
                  const InputDecoration(
                    labelText: 'Комментарий курьеру',
                    hintText: 'Дополнительные подсказки, если они нужны',
                    border: OutlineInputBorder(),
                  ),
                  controller: _commentCtrl,
                ),
              ),
              if (widget.showTimeWindow) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _afterCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'После',
                            hintText: '10:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: _afterCtrl,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _beforeCtrl,
                        decoration: withInputLanguageBadge(
                          const InputDecoration(
                            labelText: 'До',
                            hintText: '16:00',
                            border: OutlineInputBorder(),
                          ),
                          controller: _beforeCtrl,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.allowSaveAsDefault) ...[
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  value: _saveAsDefault,
                  onChanged: (value) => setState(() => _saveAsDefault = value),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Сделать адрес основным'),
                  subtitle: const Text(
                    'Тогда этот адрес появится первым в следующий раз.',
                  ),
                ),
              ],
              if (_validationMessage.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _confirmSelection
                        ? theme.colorScheme.tertiaryContainer.withValues(
                            alpha: 0.72,
                          )
                        : theme.colorScheme.errorContainer.withValues(
                            alpha: 0.72,
                          ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _validationMessage,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(
            _submitting
                ? 'Проверяем...'
                : _confirmSelection
                ? 'Подтвердить адрес'
                : 'Сохранить адрес',
          ),
        ),
      ],
    );
  }
}
