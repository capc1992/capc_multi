import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../platform/platform_services.dart';
import '../services/backup_transfer.dart';
import '../services/documents.dart';
import '../services/document_preview.dart';
import '../services/reporting.dart';
import '../services/spreadsheets.dart';
import 'access_gate.dart';
import 'account_security.dart';
import 'management_pages.dart';
import 'spreadsheet_actions.dart';
import 'ui_shared.dart';

const _navy = Color(0xFF142638);
const _green = Color(0xFF087F5B);
const _muted = Color(0xFF526174);
const _border = Color(0xFFDCE3E8);
final _moneyFormat = NumberFormat.decimalPattern('es_CO');
String _money(int value) => '\$ ${_moneyFormat.format(value)}';
DateTime _bogota(DateTime value) =>
    value.toUtc().subtract(const Duration(hours: 5));
DateTime _day(DateTime value) => DateTime(value.year, value.month, value.day);
String _date(DateTime value) => DateFormat('dd/MM/yyyy').format(value);
String _timestamp(DateTime value) =>
    DateFormat('dd/MM/yyyy · HH:mm').format(_bogota(value));

class CapcApp extends StatelessWidget {
  const CapcApp({super.key, required this.repository});
  final CapcRepository repository;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _green,
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'CAPC Multiservicio',
      debugShowCheckedModeBanner: false,
      locale: const Locale('es', 'CO'),
      supportedLocales: const [Locale('es', 'CO')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF3F6F8),
        fontFamily: 'Roboto',
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: _navy,
          ),
          titleLarge: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            color: _navy,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: _navy,
          ),
          bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: _navy),
          bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: _navy),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _border),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        dividerTheme: const DividerThemeData(color: _border, space: 24),
      ),
      home: CapcAccessGate(
        repository: repository,
        builder: (onLogout) =>
            _CapcHome(repository: repository, onLogout: onLogout),
      ),
    );
  }
}

class _CapcHome extends StatefulWidget {
  const _CapcHome({required this.repository, required this.onLogout});
  final CapcRepository repository;
  final VoidCallback onLogout;
  @override
  State<_CapcHome> createState() => _CapcHomeState();
}

class _CapcHomeState extends State<_CapcHome> {
  static const _navigation = [
    ('Resumen', Icons.space_dashboard_outlined),
    ('Nueva venta', Icons.point_of_sale_outlined),
    ('Inventario', Icons.inventory_2_outlined),
    ('Clientes y deudas', Icons.people_outline),
    ('Historial', Icons.receipt_long_outlined),
    ('Reportes', Icons.bar_chart_outlined),
    ('Configuración', Icons.settings_outlined),
    ('Caja', Icons.account_balance_outlined),
    ('Compras y proveedores', Icons.local_shipping_outlined),
    ('Cotizaciones y trabajos', Icons.assignment_outlined),
    ('Usuarios y auditoría', Icons.admin_panel_settings_outlined),
  ];
  List<Product> _products = [];
  List<Customer> _customers = [];
  List<Sale> _sales = [];
  List<Payment> _payments = [];
  List<SaleReturnRecord> _returns = [];
  final Map<String, int> _cart = {};
  final Map<String, int> _prices = {};
  final _saleSearch = TextEditingController();
  final _inventorySearch = TextEditingController();
  final _customerSearch = TextEditingController();
  final _historySearch = TextEditingController();
  final _paidController = TextEditingController(text: '0');
  final _operatorController = TextEditingController(text: 'Caja principal');
  final _receivedController = TextEditingController();
  DateTime? _dueAt;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  int _page = 0;
  int _managementRevision = 0;
  String? _customerId;
  String _paymentMode = 'Completo';
  String _paymentMethod = 'Efectivo';
  String _saleOperationId = const Uuid().v4();
  bool _onlyLowStock = false;
  static const _inventoryPageSize = 50;
  int _inventoryPage = 0;
  late DateTime _reportFrom;
  late DateTime _reportTo;
  late final Future<DeviceSummary> _deviceSummary;

  @override
  void initState() {
    super.initState();
    final today = _day(_bogota(DateTime.now()));
    _reportFrom = DateTime(today.year, today.month, 1);
    _reportTo = today;
    _deviceSummary = appPlatform.deviceSummary();
    _refresh();
  }

  @override
  void dispose() {
    for (final c in [
      _saleSearch,
      _inventorySearch,
      _customerSearch,
      _historySearch,
      _paidController,
      _operatorController,
      _receivedController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final products = await widget.repository.listProducts();
      final customers = await widget.repository.listCustomers();
      final sales = await widget.repository.listSales();
      final payments = await widget.repository.listPayments();
      final returns = await widget.repository.listSaleReturns();
      if (!mounted) return;
      setState(() {
        _products = products;
        final inventoryCount = _filteredInventoryProducts.length;
        _inventoryPage = _inventoryPage.clamp(
          0,
          inventoryCount == 0 ? 0 : (inventoryCount - 1) ~/ _inventoryPageSize,
        );
        _customers = customers;
        _sales = sales;
        _payments = payments;
        _returns = returns;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  void _notify(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? const Color(0xFF9C2525) : _navy,
        duration: Duration(seconds: error ? 7 : 4),
      ),
    );
  }

  Future<void> _refreshAll() async {
    await _refresh();
    if (mounted) setState(() => _managementRevision++);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _notify(error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Product? _product(String id) {
    for (final p in _products) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool get _manager => widget.repository.currentUser?.role != UserRole.cashier;
  bool get _owner => widget.repository.currentUser?.role == UserRole.owner;
  int get _cartTotal => _cart.entries.fold(
    0,
    (sum, e) =>
        sum + (_prices[e.key] ?? _product(e.key)?.salePrice ?? 0) * e.value,
  );
  void _changeSale(VoidCallback action) {
    setState(() {
      action();
      _saleOperationId = const Uuid().v4();
    });
  }

  void _addToCart(Product product) {
    if (_busy) return;
    final quantity = (_cart[product.id] ?? 0) + 1;
    if (!product.isService && quantity > product.stock) {
      _notify(
        'Solo hay ${product.stock} ${product.unit} disponibles de ${product.name}.',
        error: true,
      );
      return;
    }
    _changeSale(() => _cart[product.id] = quantity);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      drawer: compact ? Drawer(child: SafeArea(child: _mobileDrawer())) : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= 1250 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.5;
            return Row(
              children: [
                if (!compact) _sidebar(wide),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: constraints.maxWidth < 700 ? 16 : 28,
                          vertical: 16,
                        ),
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border(bottom: BorderSide(color: _border)),
                        ),
                        child: Row(
                          children: [
                            if (compact)
                              Builder(
                                builder: (context) => IconButton(
                                  tooltip: 'Abrir menú',
                                  onPressed: _busy
                                      ? null
                                      : Scaffold.of(context).openDrawer,
                                  icon: const Icon(Icons.menu),
                                ),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _navigation[_page].$1,
                                    key: const Key('page-title'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'CAPC MULTISERVICIO',
                                    style: TextStyle(
                                      color: _muted,
                                      fontSize: 12,
                                      letterSpacing: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (constraints.maxWidth > 780)
                              const _Tag(
                                'Guardado en este dispositivo',
                                icon: Icons.offline_pin_outlined,
                              ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Actualizar datos',
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _run(_refreshAll),
                              icon: const Icon(Icons.refresh),
                            ),
                            IconButton(
                              tooltip: 'Seguridad de mi cuenta',
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => AccountSecurityPage(
                                            repository: widget.repository,
                                          ),
                                        ),
                                      );
                                      if (mounted &&
                                          !widget.repository.isAuthenticated) {
                                        widget.onLogout();
                                      }
                                    },
                              icon: const Icon(Icons.key_outlined),
                            ),
                            IconButton(
                              tooltip: 'Cerrar sesión',
                              onPressed: _busy
                                  ? null
                                  : () {
                                      widget.repository.logout();
                                      widget.onLogout();
                                    },
                              icon: const Icon(Icons.logout),
                            ),
                          ],
                        ),
                      ),
                      if (_busy) const LinearProgressIndicator(minHeight: 3),
                      Expanded(
                        child: _loading
                            ? const Center(child: CircularProgressIndicator())
                            : _loadError != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: _Empty(
                                    title: 'No se pudieron cargar los datos',
                                    message: _loadError!,
                                    action: FilledButton.icon(
                                      onPressed: () => _run(_refresh),
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Volver a intentar'),
                                    ),
                                  ),
                                ),
                              )
                            : SingleChildScrollView(
                                key: ValueKey(_page),
                                padding: EdgeInsets.all(
                                  constraints.maxWidth < 700 ? 16 : 28,
                                ),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 1500,
                                    ),
                                    child: _pageContent(),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _mobileDrawer() => Material(
    color: _navy,
    child: Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 16),
          child: Image.asset(
            'assets/branding/capc_logo_horizontal.png',
            height: 58,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            semanticLabel: 'CAPC MULTISERVICIO',
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _navigation.length,
            itemBuilder: (context, index) =>
                !_manager && [2, 5, 8, 10].contains(index)
                ? const SizedBox.shrink()
                : ListTile(
                    key: ValueKey('navigation-${_navigation[index].$1}'),
                    selected: _page == index,
                    selectedTileColor: const Color(0xFF28465B),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    leading: Icon(
                      _navigation[index].$2,
                      color: _page == index
                          ? const Color(0xFF74E0B6)
                          : const Color(0xFFD5E0E8),
                    ),
                    title: Text(
                      _navigation[index].$1,
                      style: const TextStyle(color: Colors.white),
                    ),
                    onTap: _busy
                        ? null
                        : () {
                            setState(() => _page = index);
                            Navigator.pop(context);
                          },
                  ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Guardado en este dispositivo · Sin conexión al VPS',
            style: TextStyle(color: Color(0xFFD5E0E8), fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget _sidebar(bool wide) {
    return Container(
      width: wide ? 232 : 80,
      color: _navy,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
            child: wide
                ? Image.asset(
                    'assets/branding/capc_logo_horizontal.png',
                    height: 58,
                    fit: BoxFit.contain,
                    semanticLabel: 'CAPC MULTISERVICIO',
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/branding/capc_app_icon_master.png',
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      semanticLabel: 'CAPC',
                    ),
                  ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: _navigation.length,
              itemBuilder: (context, index) =>
                  !_manager && [2, 5, 8, 10].contains(index)
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message: _navigation[index].$1,
                        child: Material(
                          color: _page == index
                              ? const Color(0xFF28465B)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            key: ValueKey(
                              'navigation-${_navigation[index].$1}',
                            ),
                            borderRadius: BorderRadius.circular(10),
                            onTap: _busy
                                ? null
                                : () => setState(() => _page = index),
                            child: Semantics(
                              selected: _page == index,
                              button: true,
                              label: wide ? null : _navigation[index].$1,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 16,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      _navigation[index].$2,
                                      color: _page == index
                                          ? const Color(0xFF74E0B6)
                                          : const Color(0xFFD5E0E8),
                                      size: 24,
                                    ),
                                    if (wide)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            left: 12,
                                          ),
                                          child: Text(
                                            _navigation[index].$1,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: _page == index
                                                  ? FontWeight.w700
                                                  : FontWeight.w400,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          if (wide)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Versión local\nUna empresa · Una caja',
                style: TextStyle(
                  color: Color(0xFFD5E0E8),
                  fontSize: 12,
                  height: 1.8,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pageContent() => switch (_page) {
    0 => _summary(),
    1 => _newSale(),
    2 => _inventory(),
    3 => _customersPage(),
    4 => _history(),
    5 => _reports(),
    6 => _settings(),
    _ => ManagementPage(
      key: ValueKey(_page),
      repository: widget.repository,
      page: _page,
      refreshRevision: _managementRevision,
      onChanged: _refresh,
    ),
  };

  Widget _summary() {
    final today = _day(_bogota(DateTime.now()));
    final report = SalesPeriodReport(
      sales: _sales,
      payments: _payments,
      returns: _returns,
      from: today,
      to: today,
    );
    final low = _products
        .where((p) => !p.isService && p.stock <= p.minimumStock)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Tu negocio, al día',
          'Ventas y cobros de hoy, ${_date(today)}. Hora de Bogotá.',
        ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _Metric(
              'Ventas netas de hoy',
              SalesPeriodReport.money(report.netSales),
              '${report.periodSales.length} ventas; devoluciones descontadas',
              Icons.shopping_bag_outlined,
            ),
            _Metric(
              'Cobros netos de hoy',
              SalesPeriodReport.money(report.netCollections),
              'Incluye abonos y reintegros',
              Icons.payments_outlined,
            ),
            _Metric(
              'Por cobrar',
              _money(_sales.fold(0, (n, s) => n + s.balance)),
              'Saldo actual de tus clientes',
              Icons.account_balance_wallet_outlined,
            ),
            _Metric(
              'Para reponer',
              '${low.length}',
              'Materiales en mínimo o agotados',
              Icons.inventory_2_outlined,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _section(
          'Acciones de caja',
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => setState(() => _page = 1),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Nueva venta'),
                ),
                if (_manager)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _editProduct(),
                    icon: const Icon(Icons.add),
                    label: const Text('Registrar producto'),
                  ),
                if (_manager)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => setState(() => _page = 5),
                    icon: const Icon(Icons.bar_chart_outlined),
                    label: const Text('Ver resultados'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => setState(() => _page = 7),
                  icon: const Icon(Icons.account_balance_outlined),
                  label: const Text('Abrir / cerrar caja'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        _section(
          'Estado del inventario',
          children: [
            if (_products.isEmpty)
              _Empty(
                title: 'Comienza con tu catálogo',
                message:
                    'Registra materiales y servicios para hacer tu primera venta.',
                action: OutlinedButton(
                  onPressed: _busy ? null : () => setState(() => _page = 6),
                  child: const Text('Ver catálogo de ejemplo'),
                ),
              )
            else if (low.isEmpty)
              const _Notice(
                'Buen estado de stock: todos los materiales están por encima de su mínimo.',
                icon: Icons.check_circle_outline,
              )
            else
              ...low
                  .take(5)
                  .map(
                    (p) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(p.name),
                      subtitle: Text(
                        '${p.code} · Mínimo: ${p.minimumStock} ${p.unit}',
                      ),
                      trailing: _Tag('${p.stock} disponibles', warning: true),
                    ),
                  ),
            if (low.length > 5)
              TextButton(
                onPressed: () => setState(() {
                  _page = 2;
                  _onlyLowStock = true;
                  _inventoryPage = 0;
                }),
                child: Text('Ver los ${low.length} materiales para reponer'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _section(
          'Últimas ventas',
          children: [
            if (_sales.isEmpty)
              const _Empty(
                title: 'Todavía no hay ventas',
                message:
                    'Los comprobantes aparecerán aquí cuando registres una venta.',
              )
            else
              ..._sales.take(5).map(_saleRow),
          ],
        ),
      ],
    );
  }

  Widget _newSale() {
    final query = _saleSearch.text.trim().toLowerCase();
    final matches = _products
        .where((p) => '${p.code} ${p.name}'.toLowerCase().contains(query))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Registrar una venta',
          'Busca materiales o servicios y agrégalos al comprobante. Los precios están en pesos colombianos.',
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final catalog = _section(
              '1. Agregar productos y servicios',
              children: [
                _search(
                  _saleSearch,
                  'Buscar por código o nombre',
                  onSubmitted: (_) {
                    if (matches.length == 1) {
                      _addToCart(matches.first);
                    } else if (matches.isNotEmpty) {
                      final exact = matches
                          .where((p) => p.code.toLowerCase() == query)
                          .toList();
                      if (exact.length == 1) _addToCart(exact.first);
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (matches.isEmpty)
                  _Empty(
                    title: _products.isEmpty
                        ? 'Tu catálogo está vacío'
                        : 'Sin coincidencias',
                    message: _products.isEmpty
                        ? 'Registra tu primer material o servicio en Inventario.'
                        : 'Prueba con otro nombre o código.',
                    action: _products.isEmpty
                        ? OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _page = 2),
                            child: const Text('Ir a Inventario'),
                          )
                        : null,
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 490),
                    child: ListView(
                      shrinkWrap: true,
                      children: matches
                          .take(40)
                          .map(
                            (p) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEAF4EF),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      p.isService
                                          ? Icons.design_services_outlined
                                          : Icons.inventory_2_outlined,
                                      color: _green,
                                      size: 21,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${p.code} · ${p.isService ? 'Servicio' : '${p.stock} ${p.unit} disponibles'}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: _muted,
                                          ),
                                        ),
                                        Text(
                                          _money(p.salePrice),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: _green,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton.filledTonal(
                                    tooltip: 'Agregar ${p.name}',
                                    onPressed:
                                        _busy || (!p.isService && p.stock == 0)
                                        ? null
                                        : () => _addToCart(p),
                                    icon: const Icon(Icons.add),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                if (matches.length > 40)
                  Text(
                    'Se muestran 40 de ${matches.length}. Escribe para filtrar.',
                    style: const TextStyle(color: _muted),
                  ),
              ],
            );
            final cart = _section(
              '2. Comprobante de venta',
              children: [
                if (_cart.isEmpty)
                  const _Empty(
                    title: 'Agrega el primer ítem',
                    message:
                        'Puedes vender materiales y servicios en un mismo comprobante.',
                  )
                else
                  ..._cart.entries.map((entry) {
                    final p = _product(entry.key);
                    if (p == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              Text(
                                p.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _money(
                                  (_prices[p.id] ?? p.salePrice) * entry.value,
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${_money(_prices[p.id] ?? p.salePrice)} / ${p.unit}',
                            style: const TextStyle(fontSize: 12, color: _muted),
                          ),
                          if (_manager)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await entryDialog(
                                        context,
                                        title: 'Precio para esta venta',
                                        fields: [
                                          EntryField(
                                            'price',
                                            'Precio unitario (COP)',
                                            value:
                                                '${_prices[p.id] ?? p.salePrice}',
                                            number: true,
                                          ),
                                        ],
                                        onSave: (v) async {
                                          _changeSale(
                                            () => _prices[p.id] = int.parse(
                                              v['price']!,
                                            ),
                                          );
                                        },
                                      );
                                    },
                              child: const Text('Cambiar precio'),
                            ),
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Disminuir cantidad de ${p.name}',
                                onPressed: _busy
                                    ? null
                                    : () => _changeSale(() {
                                        if (entry.value <= 1) {
                                          _cart.remove(entry.key);
                                        } else {
                                          _cart[entry.key] = entry.value - 1;
                                        }
                                      }),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              Tooltip(
                                message: 'Escribir cantidad de ${p.name}',
                                child: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _setQuantity(p, entry.value),
                                  child: Text(
                                    '${entry.value}',
                                    semanticsLabel:
                                        'Cantidad de ${p.name}: ${entry.value}',
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Aumentar cantidad de ${p.name}',
                                onPressed: _busy ? null : () => _addToCart(p),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Quitar ${p.name}',
                                onPressed: _busy
                                    ? null
                                    : () => _changeSale(
                                        () => _cart.remove(entry.key),
                                      ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                    );
                  }),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    const Text(
                      'TOTAL',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _muted,
                      ),
                    ),
                    Text(
                      _money(_cartTotal),
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                DropdownButtonFormField<String>(
                  key: ValueKey('sale-customer-${_customerId ?? ''}'),
                  initialValue: _customerId ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Cliente'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Venta de contado / sin cliente'),
                    ),
                    ..._customers.map(
                      (c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => _changeSale(
                          () => _customerId = value == '' ? null : value,
                        ),
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final customerId = await _editCustomer();
                          if (customerId != null &&
                              mounted &&
                              _customers.any((c) => c.id == customerId)) {
                            _changeSale(() => _customerId = customerId);
                          }
                        },
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Nuevo cliente'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _paymentMode,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Estado del pago',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Completo',
                      child: Text('Pagada: cobro completo'),
                    ),
                    DropdownMenuItem(
                      value: 'Parcial',
                      child: Text('Abono parcial'),
                    ),
                    DropdownMenuItem(
                      value: 'Crédito',
                      child: Text('Debe: venta a crédito'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => _changeSale(() => _paymentMode = value!),
                ),
                if (_paymentMode == 'Parcial') ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _paidController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Abono inicial (COP)',
                      helperText: 'Escribe pesos enteros, sin puntos ni comas.',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => _changeSale(() {}),
                  ),
                ],
                if (_paymentMode != 'Crédito') ...[
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _paymentMethod,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Medio de pago',
                    ),
                    items: _paymentMethods,
                    onChanged: _busy
                        ? null
                        : (value) => _changeSale(() => _paymentMethod = value!),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _receivedController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Dinero recibido (COP)',
                      helperText:
                          'Vacío = importe aplicado. El cambio se calcula solo en efectivo.',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => _changeSale(() {}),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Aplicado: ${_money(_paymentMode == 'Completo' ? _cartTotal : int.tryParse(_paidController.text) ?? 0)} · Cambio: ${_money((_paymentMethod == 'Efectivo' ? (int.tryParse(_receivedController.text) ?? (_paymentMode == 'Completo' ? _cartTotal : int.tryParse(_paidController.text) ?? 0)) - (_paymentMode == 'Completo' ? _cartTotal : int.tryParse(_paidController.text) ?? 0) : 0).clamp(0, 9007199254740991))}',
                  ),
                ],
                const SizedBox(height: 16),
                Text('Vendedor: ${widget.repository.currentUser?.name ?? ''}'),
                if (_paymentMode != 'Completo') ...[
                  const SizedBox(height: 12),
                  _Notice(
                    _customerId == null
                        ? 'Selecciona un cliente para guardar la deuda a su nombre.'
                        : 'La deuda quedará asignada al cliente seleccionado.',
                    icon: Icons.person_outline,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            final d = await showDatePicker(
                              context: context,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                              initialDate: _dueAt ?? DateTime.now(),
                            );
                            if (d != null) _changeSale(() => _dueAt = d);
                          },
                    icon: const Icon(Icons.calendar_month),
                    label: Text(
                      _dueAt == null
                          ? 'Definir vencimiento'
                          : 'Vence: ${_date(_dueAt!)}',
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy || _cart.isEmpty ? null : _completeSale,
                    icon: const Icon(Icons.check),
                    label: Text(_busy ? 'Guardando…' : 'Registrar venta'),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Al confirmar se descuenta el inventario. Después podrás imprimir o guardar el comprobante.',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            );
            if (constraints.maxWidth >= 1100 &&
                MediaQuery.textScalerOf(context).scale(1) < 1.5) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: catalog),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: cart),
                ],
              );
            }
            return Column(
              children: [catalog, const SizedBox(height: 20), cart],
            );
          },
        ),
      ],
    );
  }

  List<DropdownMenuItem<String>> get _paymentMethods => const [
    DropdownMenuItem(value: 'Efectivo', child: Text('Efectivo')),
    DropdownMenuItem(value: 'Transferencia', child: Text('Transferencia')),
    DropdownMenuItem(value: 'Tarjeta', child: Text('Tarjeta')),
  ];

  Future<void> _setQuantity(Product product, int current) async {
    final quantity = TextEditingController(text: '$current');
    final form = GlobalKey<FormState>();
    String? error;
    final selected = await _formDialog<int>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Cantidad de ${product.name}'),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _formText(
                      quantity,
                      'Cantidad (${product.unit})',
                      number: true,
                      positive: true,
                    ),
                    if (!product.isService)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          'Disponible: ${product.stock} ${product.unit}',
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _FormError(error!),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                final value = int.parse(quantity.text);
                if (!product.isService && value > product.stock) {
                  update(
                    () => error = 'La cantidad supera el stock disponible.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Aplicar'),
            ),
          ],
        ),
      ),
    );
    quantity.dispose();
    if (selected != null && mounted && _cart.containsKey(product.id)) {
      _changeSale(() => _cart[product.id] = selected);
    }
  }

  Future<void> _completeSale() async {
    if (_busy || _cart.isEmpty) return;
    final total = _cartTotal;
    final paid = _paymentMode == 'Completo'
        ? total
        : _paymentMode == 'Crédito'
        ? 0
        : int.tryParse(_paidController.text);
    if (paid == null ||
        paid < 0 ||
        paid > total ||
        (_paymentMode == 'Parcial' && (paid == 0 || paid == total))) {
      _notify(
        'El abono parcial debe ser mayor que cero y menor que el total.',
        error: true,
      );
      return;
    }
    if (paid < total && _customerId == null) {
      _notify('Selecciona el cliente que quedará debiendo.', error: true);
      return;
    }
    if (paid < total && _dueAt == null) {
      _notify('Define la fecha de vencimiento de la deuda.', error: true);
      return;
    }
    final received = _paymentMode == 'Crédito'
        ? 0
        : _receivedController.text.isEmpty
        ? paid
        : int.tryParse(_receivedController.text);
    if (received == null ||
        received < paid ||
        (_paymentMethod != 'Efectivo' && received != paid)) {
      _notify(
        'Revisa el dinero recibido. Debe cubrir el importe aplicado; transferencia y tarjeta deben coincidir exactamente.',
        error: true,
      );
      return;
    }
    Sale? saved;
    await _run(() async {
      saved = await widget.repository.createSale(
        items: _cart.entries
            .map(
              (e) => CartLine(
                productId: e.key,
                quantity: e.value,
                unitPrice: _prices[e.key],
              ),
            )
            .toList(),
        customerId: _customerId,
        paid: paid,
        paymentMethod: _paymentMethod,
        operatorName: widget.repository.currentUser!.name,
        operationId: _saleOperationId,
        received: received,
        dueAt: paid < total
            ? DateTime.utc(
                _dueAt!.year,
                _dueAt!.month,
                _dueAt!.day,
                23,
                59,
                59,
              ).add(const Duration(hours: 5))
            : null,
      );
      if (!mounted) return;
      _changeSale(() {
        _cart.clear();
        _prices.clear();
        _paidController.text = '0';
        _receivedController.clear();
        _dueAt = null;
      });
      await _refresh();
      _notify('Venta ${saved!.number} guardada en este dispositivo.');
    });
    if (saved != null && mounted) await _showSale(saved!);
  }

  List<Product> get _filteredInventoryProducts {
    final query = _inventorySearch.text.trim().toLowerCase();
    return _products
        .where(
          (p) =>
              '${p.code} ${p.name}'.toLowerCase().contains(query) &&
              (!_onlyLowStock || (!p.isService && p.stock <= p.minimumStock)),
        )
        .toList();
  }

  Widget _inventory() {
    final products = _filteredInventoryProducts;
    final first = _inventoryPage * _inventoryPageSize;
    final last = (first + _inventoryPageSize).clamp(0, products.length);
    final visibleProducts = products.skip(first).take(_inventoryPageSize);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Materiales y servicios',
          'Define códigos, categorías, precios y mínimos. Configura los materiales que consume cada servicio.',
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _editProduct(),
              icon: const Icon(Icons.add),
              label: const Text('Nuevo producto o servicio'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => saveExcelFile(
                        context,
                        name: 'Plantilla-productos-CAPC',
                        build: buildProductTemplate,
                      ),
                    ),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Descargar plantilla Excel'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final count = await showProductImport(
                        context,
                        widget.repository,
                      );
                      if (count != null && mounted) {
                        setState(() => _inventoryPage = 0);
                        await _refreshAll();
                        _notify('$count productos y servicios importados.');
                      }
                    }),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Importar Excel'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => saveExcelFile(
                        context,
                        name: 'Productos-CAPC',
                        build: () =>
                            compute(CapcSpreadsheets.exportProducts, products),
                      ),
                    ),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Exportar Excel'),
            ),
            FilterChip(
              label: const Text('Solo para reponer'),
              selected: _onlyLowStock,
              onSelected: _busy
                  ? null
                  : (value) => setState(() {
                      _onlyLowStock = value;
                      _inventoryPage = 0;
                    }),
              padding: const EdgeInsets.all(12),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _search(
          _inventorySearch,
          'Buscar producto, servicio o código',
          onChanged: (_) => _inventoryPage = 0,
        ),
        const SizedBox(height: 20),
        _section(
          'Catálogo · ${products.length} ítems',
          children: [
            if (products.isNotEmpty) ...[
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${first + 1}–$last de ${products.length}',
                    key: const Key('inventory-page-range'),
                    semanticsLabel:
                        'Mostrando del ${first + 1} al $last de ${products.length} ítems',
                  ),
                  OutlinedButton.icon(
                    key: const Key('inventory-previous-page'),
                    onPressed: _busy || _inventoryPage == 0
                        ? null
                        : () => setState(() => _inventoryPage--),
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('Anterior'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('inventory-next-page'),
                    onPressed: _busy || last >= products.length
                        ? null
                        : () => setState(() => _inventoryPage++),
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('Siguiente'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (products.isEmpty)
              _Empty(
                title: _products.isEmpty
                    ? 'Registra tu primer ítem'
                    : 'Sin coincidencias',
                message: _products.isEmpty
                    ? 'Puedes crear tus propios productos o cargar ejemplos desde Configuración.'
                    : 'Cambia el texto de búsqueda o el filtro de reposición.',
              )
            else
              ...visibleProducts.map(
                (p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            p.name,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          _Tag(
                            p.isService
                                ? 'Servicio'
                                : p.stock == 0
                                ? 'Agotado'
                                : p.stock <= p.minimumStock
                                ? 'Solicitar material'
                                : 'Disponible',
                            warning: !p.isService && p.stock <= p.minimumStock,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 28,
                        runSpacing: 12,
                        children: [
                          _Detail('Código / unidad', '${p.code} / ${p.unit}'),
                          _Detail(
                            'Categoría',
                            p.category.isEmpty ? 'Sin categoría' : p.category,
                          ),
                          _Detail(
                            p.isService
                                ? 'Costo de referencia'
                                : 'Precio de compra',
                            _money(p.purchasePrice),
                          ),
                          _Detail('Precio de venta', _money(p.salePrice)),
                          if (!p.isService)
                            _Detail(
                              'Stock / mínimo',
                              '${p.stock} / ${p.minimumStock}',
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: _busy ? null : () => _editProduct(p),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Editar'),
                          ),
                          if (!p.isService)
                            TextButton.icon(
                              onPressed: _busy ? null : () => _adjustStock(p),
                              icon: const Icon(Icons.swap_vert),
                              label: const Text('Entrada / salida de stock'),
                            ),
                          if (!p.isService)
                            TextButton.icon(
                              onPressed: _busy ? null : () => _stockHistory(p),
                              icon: const Icon(Icons.history),
                              label: const Text('Movimientos'),
                            ),
                          if (p.isService)
                            TextButton.icon(
                              onPressed: _busy ? null : () => _recipe(p),
                              icon: const Icon(Icons.build_outlined),
                              label: const Text('Materiales consumidos'),
                            ),
                        ],
                      ),
                      const Divider(height: 1),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _customersPage() {
    final query = _customerSearch.text.trim().toLowerCase();
    final customers = _customers
        .where((c) => '${c.name} ${c.phone}'.toLowerCase().contains(query))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Clientes y cuentas por cobrar',
          'Asigna cada venta a su cliente y registra abonos sobre el comprobante pendiente.',
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _editCustomer(),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Nuevo cliente'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => saveTableExcel(
                        context,
                        title: 'Clientes-CAPC',
                        headers: const [
                          'Nombre',
                          'Teléfono',
                          'Saldo pendiente COP',
                        ],
                        rows: [
                          for (final customer in customers)
                            [
                              customer.name,
                              customer.phone,
                              _sales
                                  .where(
                                    (sale) => sale.customerId == customer.id,
                                  )
                                  .fold<int>(
                                    0,
                                    (sum, sale) => sum + sale.balance,
                                  ),
                            ],
                        ],
                        notes: const [
                          'Clientes de la búsqueda actual. Saldos actuales de todas las fechas.',
                        ],
                      ),
                    ),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Exportar Excel'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _search(_customerSearch, 'Buscar cliente por nombre o teléfono'),
        const SizedBox(height: 20),
        _section(
          'Clientes · ${customers.length}',
          children: [
            if (customers.isEmpty)
              const _Empty(
                title: 'No hay clientes para mostrar',
                message:
                    'Registra un cliente antes de realizar una venta a crédito.',
              )
            else
              ...customers.map((customer) {
                final debt = _sales
                    .where((s) => s.customerId == customer.id && s.balance > 0)
                    .toList();
                final balance = debt.fold(0, (sum, sale) => sum + sale.balance);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  customer.name,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  customer.phone.isEmpty
                                      ? 'Sin teléfono registrado'
                                      : customer.phone,
                                  style: const TextStyle(color: _muted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Editar ${customer.name}',
                            onPressed: _busy
                                ? null
                                : () => _editCustomer(customer),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ],
                      ),
                      _Tag(
                        balance == 0 ? 'Al día' : 'Debe ${_money(balance)}',
                        warning: balance > 0,
                      ),
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => showCapcDocument(
                                context,
                                title: 'Estado de cuenta · ${customer.name}',
                                build: () => CapcDocuments.buildStatement(
                                  customer,
                                  _sales,
                                  _payments,
                                ),
                              ),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Estado de cuenta / imprimir'),
                      ),
                      if (debt.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ...debt.map(
                          (sale) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 210,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        sale.number,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        _timestamp(sale.createdAt),
                                        style: const TextStyle(
                                          color: _muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  'Saldo ${_money(sale.balance)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _addPayment(sale),
                                  child: const Text('Registrar abono'),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _showSale(sale),
                                  child: const Text('Ver venta'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const Divider(),
                    ],
                  ),
                );
              }),
          ],
        ),
      ],
    );
  }

  Widget _history() {
    final query = _historySearch.text.trim().toLowerCase();
    final sales = _sales
        .where(
          (s) =>
              '${s.number} ${s.customerName} ${s.operatorName} ${s.lines.map((l) => '${l.code} ${l.name}').join(' ')}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Historial de ventas',
          'Consulta fecha, hora, productos y pagos. Abre un comprobante para imprimirlo o guardarlo en PDF.',
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(
                  () => saveTableExcel(
                    context,
                    title: 'Ventas-CAPC',
                    headers: const [
                      'Comprobante',
                      'Fecha Bogotá',
                      'Cliente',
                      'Estado',
                      'Total original COP',
                      'Devoluciones COP',
                      'Total neto COP',
                      'Pagado neto COP',
                      'Saldo COP',
                      'Responsable',
                    ],
                    rows: [
                      for (final sale in sales)
                        [
                          sale.number,
                          _bogota(sale.createdAt),
                          sale.customerName,
                          sale.status,
                          sale.total,
                          sale.returnedTotal,
                          sale.netTotal,
                          sale.paid,
                          sale.balance,
                          sale.operatorName,
                        ],
                    ],
                    notes: const [
                      'Ventas de la búsqueda actual con su saldo y estado actual. '
                          'Para movimientos por fecha, utiliza Reportes. '
                          'Comprobantes internos sin validez fiscal.',
                    ],
                  ),
                ),
          icon: const Icon(Icons.table_view_outlined),
          label: const Text('Exportar Excel'),
        ),
        const SizedBox(height: 20),
        _search(
          _historySearch,
          'Buscar comprobante, cliente, producto o código',
        ),
        const SizedBox(height: 20),
        _section(
          '${sales.length} ventas encontradas',
          children: [
            if (sales.isEmpty)
              const _Empty(
                title: 'No hay ventas para mostrar',
                message:
                    'Las ventas guardadas aparecerán aquí. También puedes cambiar la búsqueda.',
              )
            else
              ...sales.map(_saleRow),
          ],
        ),
      ],
    );
  }

  Widget _saleRow(Sale sale) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sale.number,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    '${_timestamp(sale.createdAt)} · ${sale.customerName}',
                    style: const TextStyle(color: _muted),
                  ),
                  Text(
                    '${sale.lines.length} ítems · ${sale.operatorName}',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _money(sale.total),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Tag(sale.status, warning: sale.balance > 0),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : () => _showSale(sale),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('Ver comprobante'),
            ),
          ],
        ),
        const Divider(height: 1),
      ],
    ),
  );

  Widget _reports() {
    final report = SalesPeriodReport(
      sales: _sales,
      payments: _payments,
      returns: _returns,
      from: _reportFrom,
      to: _reportTo,
    );
    final ranking = report.bestSellerRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _intro(
          'Resultados del negocio',
          'Ventas, cobros y devoluciones se registran en su propia fecha. Todos los períodos usan la hora de Bogotá.',
        ),
        _section(
          'Período del reporte',
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _selectReportPeriod,
                  icon: const Icon(Icons.date_range_outlined),
                  label: Text('${_date(_reportFrom)} — ${_date(_reportTo)}'),
                ),
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => showCapcDocument(
                            context,
                            title: 'Ventas y resultados',
                            build: () => CapcDocuments.buildTableDocument(
                              title:
                                  'Ventas y resultados · ${_date(_reportFrom)} al ${_date(_reportTo)}',
                              headers: [
                                'Documento',
                                'Fecha Bogotá',
                                'Operación',
                                'Importe',
                                'Costo',
                              ],
                              rows: report.salesRows,
                              notes: report.notes,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Vista previa / guardar / imprimir'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _Metric(
              'Ventas netas del período',
              SalesPeriodReport.money(report.netSales),
              'Ventas menos devoluciones y anulaciones del período',
              Icons.shopping_bag_outlined,
            ),
            _Metric(
              'Cobros netos del período',
              SalesPeriodReport.money(report.netCollections),
              'Cobros menos reintegros',
              Icons.payments_outlined,
            ),
            _Metric(
              'Utilidad bruta',
              report.costsComplete
                  ? SalesPeriodReport.moneyMicros(report.grossProfitMicros!)
                  : 'No calculada',
              report.costsComplete
                  ? 'Antes de gastos e impuestos'
                  : 'Existen costos sin verificar',
              Icons.insights_outlined,
            ),
            _Metric(
              'Cartera actual',
              _money(_sales.fold(0, (n, s) => n + s.balance)),
              'Saldos pendientes de todas las fechas',
              Icons.account_balance_wallet_outlined,
            ),
          ],
        ),
        const SizedBox(height: 16),
        const _Notice(
          'Las ventas a crédito no son cobros. Los anticipos pertenecen al flujo de caja hasta aplicarse. Solo se recupera costo cuando se recuperan materiales.',
          icon: Icons.info_outline,
        ),
        const SizedBox(height: 16),
        ManagementReports(
          repository: widget.repository,
          from: _reportFrom,
          to: _reportTo,
        ),
        const SizedBox(height: 20),
        _section(
          'Productos y servicios más vendidos',
          children: [
            if (ranking.isEmpty)
              const _Empty(
                title: 'Sin movimientos en este período',
                message:
                    'Selecciona otro rango de fechas o registra tu primera venta.',
              )
            else
              ...ranking.map(
                (row) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      Text(
                        row[0],
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text('${row[1]} unidades netas'),
                      Text(row[2]),
                    ],
                  ),
                ),
              ),
            const Text(
              'Las unidades netas pueden ser negativas cuando se devuelven ventas anteriores.',
              style: TextStyle(color: _muted),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _selectReportPeriod() async {
    final range = await showDateRangePicker(
      context: context,
      locale: const Locale('es', 'CO'),
      firstDate: DateTime(2020),
      lastDate: _day(_bogota(DateTime.now())).add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _reportFrom, end: _reportTo),
      helpText: 'Período del reporte',
      saveText: 'Aplicar',
    );
    if (range != null && mounted) {
      setState(() {
        _reportFrom = range.start;
        _reportTo = range.end;
      });
    }
  }

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _intro(
        'Configuración y respaldo',
        'Esta versión trabaja con los datos guardados en este dispositivo.',
      ),
      _section(
        'Tu espacio de trabajo',
        children: [
          const _Detail('Negocio', 'CAPC MULTISERVICIO'),
          const SizedBox(height: 16),
          const _Detail(
            'Modalidad',
            'Una empresa · Una caja local · Pesos colombianos',
          ),
          const SizedBox(height: 16),
          FutureBuilder<DeviceSummary>(
            future: _deviceSummary,
            builder: (context, snapshot) => _Detail(
              'Dispositivo',
              snapshot.hasData
                  ? '${snapshot.data!.platform} · ${snapshot.data!.description}'
                  : appPlatform.platformLabel,
            ),
          ),
          const SizedBox(height: 16),
          const _Notice(
            'Puedes vender sin internet. Esta versión todavía no comparte datos con otros equipos ni se conecta al VPS.',
            icon: Icons.offline_pin_outlined,
          ),
        ],
      ),
      const SizedBox(height: 20),
      _section(
        'Copia de seguridad',
        children: [
          Text(
            appPlatform.isAndroid
                ? 'Exporta una copia mediante el selector de documentos de Android. Conserva varias copias con fecha fuera de la aplicación.'
                : 'Guarda una copia de la base de datos en otra carpeta o en una memoria USB. Conserva varias copias con fecha.',
          ),
          const SizedBox(height: 16),
          if (_manager)
            FilledButton.icon(
              onPressed: _busy ? null : _backup,
              icon: const Icon(Icons.save_alt),
              label: const Text('Guardar copia de seguridad'),
            ),
          const SizedBox(height: 16),
          const Text(
            'Ubicación privada de los datos en este dispositivo',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          SelectableText(
            widget.repository.databasePath,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (_owner) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.restore),
              label: const Text('Restaurar respaldo'),
            ),
          ],
          const Text(
            'La restauración valida el archivo y conserva una copia previa. Después deberás iniciar sesión otra vez.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 20),
      _section(
        'Catálogo de ejemplo',
        children: [
          const Text(
            'Incluye materiales y servicios para un café internet. Revisa los precios y ajusta las existencias antes de usarlo en tu negocio. No crea ventas ni clientes.',
          ),
          const SizedBox(height: 16),
          if (_manager)
            OutlinedButton.icon(
              onPressed: _busy || _products.isNotEmpty ? null : _loadExamples,
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Cargar catálogo de ejemplo'),
            ),
          if (_products.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Disponible únicamente cuando el catálogo está vacío.',
                style: TextStyle(color: _muted),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      _section(
        'Impresión',
        children: [
          Text(
            appPlatform.isAndroid
                ? 'Abre una venta en Historial para ver, guardar, compartir o imprimir el PDF mediante los diálogos de Android.'
                : 'Abre una venta en Historial y elige Imprimir tirilla (80 mm), Imprimir carta o Guardar PDF. El diálogo de Windows permite seleccionar tu impresora instalada.',
          ),
          const SizedBox(height: 12),
          Text(
            appPlatform.isAndroid
                ? 'Los documentos son comprobantes internos sin validez fiscal. Android no accede directamente a la impresora USB conectada al computador y nunca envía documentos automáticamente.'
                : 'Los documentos son comprobantes internos sin validez fiscal. La compatibilidad de tu impresora USB debe comprobarse con su controlador instalado.',
            style: const TextStyle(color: _muted),
          ),
        ],
      ),
    ],
  );

  Future<void> _backup() => _run(() async {
    final name =
        'CAPC-respaldo-${DateFormat('yyyyMMdd-HHmmss').format(_bogota(DateTime.now()))}.sqlite';
    final saved = await BackupTransfer.exportBackup(
      widget.repository,
      suggestedName: name,
    );
    if (saved == null) return;
    _notify('Copia de seguridad guardada.');
  });

  Future<void> _restore() => _run(() async {
    final selected = await BackupTransfer.prepareImport();
    if (selected == null || !mounted) return;
    try {
      if (!await confirmAction(
        context,
        'Restaurar respaldo',
        'Se validará el archivo y se reemplazarán los datos activos. Se conservará una copia de los datos actuales antes del cambio. Archivo: ${selected.originalName}',
        action: 'Validar y restaurar',
      )) {
        return;
      }
      final previous = await widget.repository.restoreFrom(selected.path);
      if (!mounted) return;
      _notify('Restauración completada. Copia previa: $previous');
      widget.onLogout();
    } finally {
      await selected.dispose();
    }
  });

  Future<void> _loadExamples() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cargar catálogo de ejemplo'),
        content: const SizedBox(
          width: 440,
          child: Text(
            'Se agregarán productos y servicios de ejemplo con precios y existencias de referencia. Revisa estos valores antes de registrar ventas reales.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cargar ejemplos'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await widget.repository.loadExampleCatalog();
      await _refresh();
      _notify('Catálogo de ejemplo cargado. Revisa precios y existencias.');
    });
  }

  // Wait for the route to leave the overlay before disposing form controllers.
  Future<T?> _formDialog<T>({required WidgetBuilder builder}) async {
    final route = DialogRoute<T>(
      context: context,
      barrierDismissible: false,
      builder: builder,
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    return result;
  }

  Future<void> _editProduct([Product? product]) async {
    var recipe = <ServiceMaterial>[];
    try {
      if (product?.isService == true) {
        recipe = await widget.repository.listServiceRecipe(product!.id);
      }
    } catch (e) {
      _notify(e.toString(), error: true);
      return;
    }
    if (!mounted) return;
    final fields = <String, TextEditingController>{
      'code': TextEditingController(text: product?.code ?? ''),
      'name': TextEditingController(text: product?.name ?? ''),
      'unit': TextEditingController(text: product?.unit ?? 'unidad'),
      'purchase': TextEditingController(text: '${product?.purchasePrice ?? 0}'),
      'sale': TextEditingController(text: '${product?.salePrice ?? 0}'),
      'stock': TextEditingController(text: '${product?.stock ?? 0}'),
      'minimum': TextEditingController(text: '${product?.minimumStock ?? 0}'),
      'category': TextEditingController(text: product?.category ?? ''),
      'markup': TextEditingController(),
    };
    final form = GlobalKey<FormState>();
    var service = product?.isService ?? false;
    var busy = false;
    String? error;
    final saved = await _formDialog<bool>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(
              product == null
                  ? 'Nuevo producto o servicio'
                  : 'Editar ${product.name}',
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Es un servicio'),
                        subtitle: Text(
                          product == null
                              ? 'Los servicios no descuentan stock.'
                              : 'El tipo se conserva después de crear el ítem.',
                        ),
                        value: service,
                        onChanged: busy || product != null
                            ? null
                            : (value) => update(() => service = value),
                      ),
                      _formText(
                        fields['code']!,
                        'Código del ítem',
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      _formText(fields['name']!, 'Nombre', enabled: !busy),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: fields['category'],
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Categoría',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _formText(
                        fields['unit']!,
                        'Unidad (unidad, hoja, hora...)',
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      _formText(
                        fields['purchase']!,
                        service
                            ? 'Costo directo adicional del servicio (COP)'
                            : 'Precio de compra (COP)',
                        number: true,
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      _formText(
                        fields['sale']!,
                        'Precio de venta (COP)',
                        number: true,
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: fields['markup'],
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Recargo elegido sobre costo (%)',
                          helperText:
                              'Opcional. Escribe tu porcentaje antes de solicitar una sugerencia.',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () {
                                final cost =
                                    int.tryParse(fields['purchase']!.text) ?? 0;
                                final percent = int.tryParse(
                                  fields['markup']!.text,
                                );
                                try {
                                  if (percent == null ||
                                      percent < 0 ||
                                      percent > 100000) {
                                    throw const CapcException(
                                      'Escribe el porcentaje de recargo que deseas aplicar.',
                                    );
                                  }
                                  var micros =
                                      BigInt.from(cost) * BigInt.from(1000000);
                                  if (service) {
                                    for (final part in recipe) {
                                      final material = _product(part.productId);
                                      if (material == null ||
                                          !material.costKnown) {
                                        throw const CapcException(
                                          'Verifica primero el costo de los materiales del servicio.',
                                        );
                                      }
                                      micros +=
                                          BigInt.from(
                                            material.averageCostMicros,
                                          ) *
                                          BigInt.from(part.quantity);
                                    }
                                  }
                                  final divisor = BigInt.from(100000000);
                                  final suggested = !service && product != null
                                      ? product.suggestedPrice(percent * 100)
                                      : ((micros * BigInt.from(100 + percent) +
                                                    divisor ~/ BigInt.two) ~/
                                                divisor)
                                            .toInt();
                                  fields['sale']!.text = '$suggested';
                                } catch (e) {
                                  update(() => error = e.toString());
                                }
                              },
                        icon: const Icon(Icons.calculate_outlined),
                        label: const Text(
                          'Aplicar precio sugerido (puedes editarlo)',
                        ),
                      ),
                      const Text(
                        'La sugerencia no cambia el precio hasta que la apliques. En materiales existentes usa el costo promedio; editar el costo de compra no revalúa el stock. En servicios suma costo directo y materiales configurados.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                      if (!service) ...[
                        const SizedBox(height: 16),
                        if (product == null) ...[
                          _formText(
                            fields['stock']!,
                            'Stock inicial',
                            number: true,
                            enabled: !busy,
                          ),
                          const SizedBox(height: 16),
                        ] else ...[
                          Text(
                            'Stock actual: ${product.stock} ${product.unit}. Para cambiarlo usa Entrada / salida de stock.',
                          ),
                          const SizedBox(height: 16),
                        ],
                        _formText(
                          fields['minimum']!,
                          'Stock mínimo',
                          number: true,
                          enabled: !busy,
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text(
                        'Usa pesos y cantidades enteros, sin puntos ni comas.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        _FormError(error!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        if (!form.currentState!.validate()) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.saveProduct(
                            Product(
                              id: product?.id ?? '',
                              code: fields['code']!.text.trim(),
                              name: fields['name']!.text.trim(),
                              unit: fields['unit']!.text.trim(),
                              isService: service,
                              purchasePrice: int.parse(
                                fields['purchase']!.text,
                              ),
                              salePrice: int.parse(fields['sale']!.text),
                              stock: service
                                  ? 0
                                  : int.parse(fields['stock']!.text),
                              minimumStock: service
                                  ? 0
                                  : int.parse(fields['minimum']!.text),
                              category: fields['category']!.text.trim(),
                            ),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            update(() {
                              busy = false;
                              error = e.toString();
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Guardando…' : 'Guardar ítem'),
              ),
            ],
          ),
        ),
      ),
    );
    for (final controller in fields.values) {
      controller.dispose();
    }
    if (saved == true && mounted) {
      await _refresh();
      _notify('Ítem guardado.');
    }
  }

  Future<void> _adjustStock(Product product) async {
    final quantity = TextEditingController();
    final reason = TextEditingController();
    final totalCost = TextEditingController();
    final operationId = const Uuid().v4();
    final form = GlobalKey<FormState>();
    var direction = 'Entrada';
    var busy = false;
    String? error;
    final saved = await _formDialog<bool>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text('Stock de ${product.name}'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Disponible: ${product.stock} ${product.unit}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 20),
                      DropdownButtonFormField<String>(
                        initialValue: direction,
                        decoration: const InputDecoration(
                          labelText: 'Tipo de movimiento',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'Entrada',
                            child: Text('Entrada de material'),
                          ),
                          DropdownMenuItem(
                            value: 'Salida',
                            child: Text('Salida / ajuste'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => update(() => direction = v!),
                      ),
                      const SizedBox(height: 16),
                      _formText(
                        quantity,
                        'Cantidad',
                        number: true,
                        positive: true,
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      _formText(
                        reason,
                        'Motivo del movimiento',
                        enabled: !busy,
                      ),
                      if (direction == 'Entrada') ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: totalCost,
                          validator: _optionalMoney,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Costo total de la entrada (COP)',
                            helperText:
                                'Vacío: se aplicará la regla de costo del inventario.',
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text(
                        'Ejemplos: recepción de material, corrección de conteo o material dañado. Este ajuste no registra una compra ni una deuda a un proveedor.',
                        style: TextStyle(color: _muted),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        _FormError(error!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        if (!form.currentState!.validate()) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.adjustStock(
                            product.id,
                            int.parse(quantity.text) *
                                (direction == 'Entrada' ? 1 : -1),
                            reason.text.trim(),
                            totalCost: direction == 'Entrada'
                                ? int.tryParse(totalCost.text)
                                : null,
                            operationId: operationId,
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            update(() {
                              busy = false;
                              error = e.toString();
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Guardando…' : 'Guardar movimiento'),
              ),
            ],
          ),
        ),
      ),
    );
    quantity.dispose();
    reason.dispose();
    totalCost.dispose();
    if (saved == true && mounted) {
      await _refresh();
      _notify('Movimiento de stock registrado.');
    }
  }

  Future<String?> _editCustomer([Customer? customer]) async {
    final customerId = customer?.id ?? const Uuid().v4();
    final name = TextEditingController(text: customer?.name ?? '');
    final phone = TextEditingController(text: customer?.phone ?? '');
    final form = GlobalKey<FormState>();
    var busy = false;
    String? error;
    final saved = await _formDialog<bool>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(customer == null ? 'Nuevo cliente' : 'Editar cliente'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _formText(name, 'Nombre del cliente', enabled: !busy),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: phone,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Teléfono (opcional)',
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        _FormError(error!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        if (!form.currentState!.validate()) return;
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.saveCustomer(
                            Customer(
                              id: customerId,
                              name: name.text.trim(),
                              phone: phone.text.trim(),
                            ),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            update(() {
                              busy = false;
                              error = e.toString();
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Guardando…' : 'Guardar cliente'),
              ),
            ],
          ),
        ),
      ),
    );
    name.dispose();
    phone.dispose();
    if (saved == true && mounted) {
      await _refresh();
      _notify('Cliente guardado.');
      return customerId;
    }
    return null;
  }

  Future<void> _addPayment(Sale sale) async {
    final amount = TextEditingController(text: '${sale.balance}');
    final received = TextEditingController();
    final operationId = const Uuid().v4();
    final form = GlobalKey<FormState>();
    var method = 'Efectivo';
    var busy = false;
    String? error;
    final saved = await _formDialog<bool>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text('Abono a ${sale.number}'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sale.customerName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('Saldo pendiente: ${_money(sale.balance)}'),
                      const SizedBox(height: 20),
                      _formText(
                        amount,
                        'Valor del abono (COP)',
                        number: true,
                        positive: true,
                        enabled: !busy,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: method,
                        decoration: const InputDecoration(
                          labelText: 'Medio de pago',
                        ),
                        items: _paymentMethods,
                        onChanged: busy
                            ? null
                            : (value) => update(() => method = value!),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: received,
                        validator: _optionalMoney,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Dinero recibido (COP)',
                          helperText:
                              'Vacío = valor del abono. El excedente en efectivo se devuelve como cambio.',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        _FormError(error!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        if (busy) return;
                        if (!form.currentState!.validate()) return;
                        if (int.parse(amount.text) > sale.balance) {
                          update(
                            () => error =
                                'El abono no puede superar el saldo pendiente.',
                          );
                          return;
                        }
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.addPayment(
                            sale.id,
                            int.parse(amount.text),
                            method,
                            operationId: operationId,
                            received: int.tryParse(received.text),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        } catch (e) {
                          if (dialogContext.mounted) {
                            update(() {
                              busy = false;
                              error = e.toString();
                            });
                          }
                        }
                      },
                child: Text(busy ? 'Guardando…' : 'Registrar abono'),
              ),
            ],
          ),
        ),
      ),
    );
    amount.dispose();
    received.dispose();
    if (saved == true && mounted) {
      await _refresh();
      _notify('Abono guardado y saldo actualizado.');
    }
  }

  Future<void> _showSale(Sale sale) async {
    final returns = _returns.where((r) => r.saleId == sale.id).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final names = {for (final line in sale.lines) line.id: line.name};
    final payments = _payments.where((p) => p.saleId == sale.id).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          Future<void> document(Future<void> Function() action) async {
            if (busy) return;
            update(() {
              busy = true;
              error = null;
            });
            try {
              await action();
            } catch (e) {
              if (dialogContext.mounted) update(() => error = e.toString());
            } finally {
              if (dialogContext.mounted) update(() => busy = false);
            }
          }

          return PopScope(
            canPop: !busy,
            child: AlertDialog(
              title: Text('Comprobante ${sale.number}'),
              content: SizedBox(
                width: 680,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CAPC MULTISERVICIO',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text('${_timestamp(sale.createdAt)} · Hora de Bogotá'),
                      Text('Cliente: ${sale.customerName}'),
                      Text('Registrado por: ${sale.operatorName}'),
                      const SizedBox(height: 12),
                      _Tag(sale.status, warning: sale.balance > 0),
                      const Divider(),
                      ...sale.lines.map(
                        (line) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      '${line.code} · ${line.quantity} ${line.unit} × ${_money(line.unitPrice)}',
                                      style: const TextStyle(color: _muted),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Text(
                                _money(line.total),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(),
                      _totalRow('Total', sale.total),
                      _totalRow('Pagado', sale.paid),
                      _totalRow('Saldo pendiente', sale.balance),
                      _totalRow('Recibido inicial', sale.received),
                      _totalRow('Cambio inicial', sale.change),
                      if (sale.returnedTotal > 0)
                        _totalRow(
                          'Valor devuelto / anulado',
                          sale.returnedTotal,
                        ),
                      if (sale.dueAt != null)
                        Text('Vencimiento: ${localDate(sale.dueAt)}'),
                      const SizedBox(height: 20),
                      const Text(
                        'Cobros y reintegros registrados',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (payments.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Esta venta no tiene pagos todavía.'),
                        )
                      else
                        ...payments.map(
                          (payment) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '${payment.kind} · ${_timestamp(payment.createdAt)} · ${payment.method} · ${_money(payment.amount)}',
                            ),
                          ),
                        ),
                      if (returns.isNotEmpty) ...[
                        const Divider(),
                        const Text(
                          'Historial de devoluciones y anulaciones',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        for (final reversal in returns)
                          DataCard(
                            title:
                                '${reversal.number} · ${reversal.cancelled ? 'Anulación' : 'Devolución'}',
                            subtitle:
                                '${localDate(reversal.createdAt)} · ${reversal.actorName}',
                            children: [
                              Text('Motivo: ${reversal.reason}'),
                              Text(
                                'Valor compensado: ${_money(reversal.amount)} · Reintegro: ${_money(reversal.refund)} · ${reversal.method}',
                              ),
                              for (final item in reversal.items)
                                Text(
                                  '${item.quantity} × ${names[item.saleLineId] ?? 'Concepto original'} · ${item.restock ? 'Reintegrado a existencias' : 'Sin reposición de material'}',
                                ),
                            ],
                          ),
                      ],
                      const Divider(),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(
                                    () => showCapcDocument(
                                      context,
                                      title: 'Comprobante ${sale.number}',
                                      build: () =>
                                          CapcDocuments.buildSale(sale),
                                    ),
                                  ),
                            icon: const Icon(Icons.preview_outlined),
                            label: const Text('Vista previa Carta'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(
                                    () => showCapcDocument(
                                      context,
                                      title: 'Tirilla ${sale.number}',
                                      ticket: true,
                                      build: () => CapcDocuments.buildSale(
                                        sale,
                                        ticket: true,
                                      ),
                                    ),
                                  ),
                            icon: const Icon(Icons.preview_outlined),
                            label: const Text('Vista previa 80 mm'),
                          ),
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(
                                    () => CapcDocuments.printSale(
                                      sale,
                                      ticket: true,
                                    ),
                                  ),
                            icon: const Icon(Icons.receipt_outlined),
                            label: const Text('Imprimir tirilla (80 mm)'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(
                                    () => CapcDocuments.printSale(sale),
                                  ),
                            icon: const Icon(Icons.print_outlined),
                            label: const Text('Imprimir carta'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(() async {
                                    if (await CapcDocuments.saveSale(sale)) {
                                      _notify('Comprobante PDF guardado.');
                                    }
                                  }),
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('Guardar PDF carta'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => document(() async {
                                    if (await CapcDocuments.saveSale(
                                      sale,
                                      ticket: true,
                                    )) {
                                      _notify('Tirilla PDF guardada.');
                                    }
                                  }),
                            icon: const Icon(Icons.save_alt),
                            label: const Text('Guardar PDF tirilla'),
                          ),
                          if (_manager && !sale.cancelled)
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (await _return(sale, cancel: false) &&
                                          dialogContext.mounted) {
                                        Navigator.pop(dialogContext);
                                      }
                                    },
                              icon: const Icon(Icons.undo),
                              label: const Text('Devolución'),
                            ),
                          if (_manager && !sale.cancelled)
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (await _return(sale, cancel: true) &&
                                          dialogContext.mounted) {
                                        Navigator.pop(dialogContext);
                                      }
                                    },
                              icon: const Icon(Icons.cancel_outlined),
                              label: const Text('Anular venta'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Comprobante interno · Sin validez fiscal',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator(),
                        ),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        _FormError(error!),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cerrar'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _stockHistory(Product product) => _run(() async {
    final rows = await widget.repository.listStockMovements(
      productId: product.id,
    );
    if (!mounted) return;
    await showCapcDocument(
      context,
      title: 'Movimientos · ${product.name}',
      build: () => CapcDocuments.buildTableDocument(
        title: 'Historial de inventario · ${product.name}',
        headers: [
          'Fecha Bogotá',
          'Movimiento',
          'Cantidad',
          'Responsable',
          'Motivo',
        ],
        rows: rows
            .map(
              (m) => [
                localDate(m.createdAt),
                operationLabel(m.kind),
                '${m.delta}',
                m.actorName,
                m.reason,
              ],
            )
            .toList(),
      ),
    );
  });

  Future<void> _recipe(Product service) => _run(() async {
    final recipe = await widget.repository.listServiceRecipe(service.id);
    final materials = _products.where((p) => !p.isService).toList();
    if (!mounted) return;
    await entryDialog(
      context,
      title: 'Materiales por unidad de ${service.name}',
      notice:
          'Escribe 0 para no consumir un material. Las cantidades se descontarán al confirmar la venta del servicio.',
      fields: [
        for (final p in materials)
          EntryField(
            p.id,
            '${p.code} · ${p.name} (${p.unit})',
            value:
                '${recipe.where((r) => r.productId == p.id).fold(0, (n, r) => n + r.quantity)}',
            number: true,
          ),
      ],
      onSave: (v) => widget.repository.setServiceRecipe(service.id, [
        for (final p in materials)
          if ((int.tryParse(v[p.id] ?? '') ?? 0) > 0)
            ServiceMaterial(productId: p.id, quantity: int.parse(v[p.id]!)),
      ]),
    );
    await _refresh();
  });

  Future<bool> _return(Sale sale, {required bool cancel}) async {
    final operationId = const Uuid().v4();
    final done = await entryDialog(
      context,
      title: cancel
          ? 'Anular ${sale.number}'
          : 'Devolver conceptos de ${sale.number}',
      notice:
          'Se conservará el comprobante original y se registrarán movimientos compensatorios. Revisa si los materiales pueden regresar a existencias.',
      fields: [
        const EntryField('reason', 'Motivo'),
        const EntryField(
          'method',
          'Medio para reintegro',
          value: 'Efectivo',
          options: paymentOptions,
        ),
        const EntryField(
          'restock',
          'Tratamiento del inventario',
          value: 'yes',
          options: {
            'yes': 'Devolver materiales a existencias',
            'no': 'No reponer: consumido / dañado',
          },
        ),
        if (!cancel)
          for (final line in sale.lines.where(
            (l) => l.returnedQuantity < l.quantity,
          ))
            EntryField(
              line.id,
              '${line.name} · máximo ${line.quantity - line.returnedQuantity}',
              value: '0',
              number: true,
            ),
      ],
      onSave: (v) async {
        if (cancel) {
          await widget.repository.cancelSale(
            sale.id,
            reason: v['reason']!,
            method: v['method']!,
            restoreMaterials: v['restock'] == 'yes',
            operationId: operationId,
          );
        } else {
          await widget.repository.returnSale(
            sale.id,
            [
              for (final line in sale.lines)
                if ((int.tryParse(v[line.id] ?? '') ?? 0) > 0)
                  SaleReturnItem(
                    saleLineId: line.id,
                    quantity: int.parse(v[line.id]!),
                    restock: v['restock'] == 'yes',
                  ),
            ],
            reason: v['reason']!,
            method: v['method']!,
            operationId: operationId,
          );
        }
      },
      saveLabel: cancel ? 'Registrar anulación' : 'Registrar devolución',
    );
    if (done && mounted) await _refresh();
    return done;
  }

  Widget _totalRow(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        Text(label),
        Text(
          _money(value),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _search(
    TextEditingController controller,
    String label, {
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) => TextField(
    controller: controller,
    enabled: !_busy,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.search),
      suffixIcon: controller.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Limpiar búsqueda',
              onPressed: () => setState(() {
                controller.clear();
                onChanged?.call('');
              }),
              icon: const Icon(Icons.close),
            ),
    ),
    onChanged: (value) => setState(() => onChanged?.call(value)),
    onSubmitted: onSubmitted,
  );

  Widget _intro(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(subtitle, style: const TextStyle(color: _muted, fontSize: 14)),
      ],
    ),
  );

  Widget _section(String title, {required List<Widget> children}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        ...children,
      ],
    ),
  );

  String? _optionalMoney(String? value) =>
      value != null && value.isNotEmpty && int.tryParse(value) == null
      ? 'Escribe un valor entero válido.'
      : null;

  Widget _formText(
    TextEditingController controller,
    String label, {
    bool number = false,
    bool positive = false,
    bool enabled = true,
  }) => TextFormField(
    controller: controller,
    enabled: enabled,
    decoration: InputDecoration(labelText: label),
    keyboardType: number ? TextInputType.number : TextInputType.text,
    inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
    validator: (value) {
      if (value == null || value.trim().isEmpty) return 'Completa este campo.';
      if (number) {
        final parsed = int.tryParse(value);
        if (parsed == null || parsed < (positive ? 1 : 0)) {
          return positive
              ? 'Escribe un entero mayor que cero.'
              : 'Escribe un entero igual o mayor que cero.';
        }
      }
      return null;
    },
  );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.description, this.icon);
  final String label, value, description;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: 245,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(icon, color: _green),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          value,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: _navy,
          ),
        ),
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(color: _muted, fontSize: 12)),
      ],
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.warning = false, this.icon});
  final String text;
  final bool warning;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: warning ? const Color(0xFFFFF2DA) : const Color(0xFFE6F3EC),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(
            icon,
            size: 16,
            color: warning ? const Color(0xFF825100) : const Color(0xFF176244),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: warning
                  ? const Color(0xFF825100)
                  : const Color(0xFF176244),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.icon});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFF0F5F7),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _muted, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: const TextStyle(color: _muted)),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.message, this.action});
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(message, style: const TextStyle(color: _muted)),
        if (action != null) ...[const SizedBox(height: 16), action!],
      ],
    ),
  );
}

class _FormError extends StatelessWidget {
  const _FormError(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEDEC),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message, style: const TextStyle(color: Color(0xFF982C25))),
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );
}
