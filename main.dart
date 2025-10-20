
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..startRealtime(),
      child: MyApp(),
    ),
  );
}



enum OrderSide { buy, sell }

class Quote {
  final String symbol;
  double ltp;
  double change;
  double percent;
  Quote({
    required this.symbol,
    required this.ltp,
    required this.change,
    required this.percent,
  });
}

class Order {
  final String id;
  final String symbol;
  final OrderSide side;
  final int qty;
  final double price;
  final DateTime createdAt;
  String status;
  Order({
    required this.id,
    required this.symbol,
    required this.side,
    required this.qty,
    required this.price,
    required this.createdAt,
    this.status = 'OPEN',
  });
}

class Holding {
  final String symbol;
  int qty;
  double avg;
  Holding({required this.symbol, required this.qty, required this.avg});
}

class AppState extends ChangeNotifier {

  List<String> watchlist = [
    'RELIANCE',
    'TCS',
    'INFY',
    'BHEL',
    'ASIANPAINT',
    'SENSEX',
    'NIFTY',
  ];

  final Map<String, Quote> quotes = {};
  final List<Order> orders = [];
  final List<Holding> holdings = [
    Holding(symbol: 'RELIANCE', qty: 2, avg: 2500.00),
    Holding(symbol: 'BHEL', qty: 43, avg: 64.92),
    Holding(symbol: 'INFY', qty: 10, avg: 1200.00),
  ];

  AlphaVantageMarketService? _marketService;

  void startRealtime() {
    // I have used my own alphavantage key... you should be using your own.
    // You can also use yahoo finance API
       const alphaKey = 'your_API_key_xxx';

    _marketService = AlphaVantageMarketService(
      apiKey: alphaKey,
      interval: Duration(seconds: 15),
    );

    _marketService!.stream.listen((incoming) {
      // incoming is Map<String, Quote>
      for (var e in incoming.entries) {
        // normalize key: use uppercase w/out spaces
        final k = e.key.toString().toUpperCase().replaceAll(' ', '');
        quotes[k] = e.value;
      }
      notifyListeners();
    });

    _marketService!.start(watchlist);
  }

  void stopRealtime() {
    _marketService?.stop();
  }

  void addToWatchlist(String symbol) {
    final s = symbol.toUpperCase().trim();
    if (s.isEmpty) return;
    if (!watchlist.contains(s)) {
      watchlist.insert(0, s);
      quotes[s.replaceAll(' ', '')] = Quote(symbol: s, ltp: 0.0, change: 0, percent: 0);
      _marketService?.addSymbol(s);
      notifyListeners();
    }
  }

  void placeOrder({
    required String symbol,
    required OrderSide side,
    required int qty,
    required double price,
  }) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final o = Order(
      id: id,
      symbol: symbol,
      side: side,
      qty: qty,
      price: price,
      createdAt: DateTime.now(),
    );
    orders.insert(0, o);

    final h = holdings.firstWhere(
          (hh) => hh.symbol == symbol,
      orElse: () => Holding(symbol: symbol, qty: 0, avg: price),
    );

    if (!holdings.contains(h)) holdings.add(h);

    if (side == OrderSide.buy) {
      final totalOld = h.avg * h.qty;
      final totalNew = price * qty;
      final newQty = h.qty + qty;
      final newAvg = (totalOld + totalNew) / (newQty == 0 ? 1 : newQty);
      h.qty = newQty;
      h.avg = newAvg;
    } else {
      h.qty = max(0, h.qty - qty);
    }

    notifyListeners();
  }

  Quote getQuote(String symbol) {
    final key = symbol.toUpperCase().replaceAll(' ', '');
    return quotes[key] ?? Quote(symbol: symbol, ltp: 0.0, change: 0.0, percent: 0.0);
  }
}


class AlphaVantageMarketService {
  final String apiKey;
  final Duration interval;
  final StreamController<Map<String, Quote>> _controller = StreamController.broadcast();

  Stream<Map<String, Quote>> get stream => _controller.stream;

  Timer? _timer;
  List<String> _symbols = [];
  int _index = 0;
  bool _running = false;

  static final Map<String, List<String>> _symbolVariantsOverride = {
    'RELIANCE': ['RELIANCE.NS', 'RELIANCE.BSE', 'RELIANCE', 'RIL.BSE', 'RIL.NSE'],
    'TCS': ['TCS.NS', 'TCS.BSE', 'TCS'],
    'INFY': ['INFY.NS', 'INFY.BSE', 'INFY'],
    'BHEL': ['BHEL.NS', 'BHEL.BSE', 'BHEL'],
    'ASIANPAINT': ['ASIANPAINT.NS', 'ASIANPAINT.BSE', 'ASIANPAINT'],
    'SENSEX': ['BSE', 'SENSEX'],
    'NIFTY': ['NSE', 'NIFTY50'],
  };

  AlphaVantageMarketService({required this.apiKey, this.interval = const Duration(seconds: 15)});

  void start(List<String> symbols) {
    if (_running) return;
    _running = true;
    _symbols = symbols.map(_normalizeSymbol).where((s) => s.isNotEmpty).toList();
    if (_symbols.isEmpty) return;

    _pollNext();
    _timer = Timer.periodic(interval, (_) => _pollNext());
  }

  void stop() {
    _timer?.cancel();
    if (!_controller.isClosed) _controller.close();
    _running = false;
  }

  void addSymbol(String symbol) {
    final s = _normalizeSymbol(symbol);
    if (s.isEmpty) return;
    if (!_symbols.contains(s)) _symbols.add(s);
  }

  String _normalizeSymbol(String s) {
    return s.trim().replaceAll(' ', '').toUpperCase();
  }

  Future<void> _pollNext() async {
    if (_symbols.isEmpty) return;
    final symbol = _symbols[_index % _symbols.length];
    _index++;
    try {
      final quote = await _fetchGlobalQuoteWithVariants(symbol);
      if (quote != null) {
        _controller.add({quote.symbol.toUpperCase().replaceAll(' ', ''): quote});
      }
    } catch (e) {
      if (kDebugMode) debugPrint('AlphaVantage poll error for $symbol: $e');
    }
  }

  Future<Quote?> _fetchGlobalQuoteWithVariants(String baseSymbol) async {
    final override = _symbolVariantsOverride[baseSymbol];
    final candidateList = <String>[];
    if (override != null && override.isNotEmpty) {
      candidateList.addAll(override);
    } else {
      candidateList.addAll([
        baseSymbol,
        '$baseSymbol.NS',
        '$baseSymbol.BSE',
        'NSE:$baseSymbol',
        'BSE:$baseSymbol',
      ]);
    }

    for (final v in candidateList) {
      final quote = await _fetchGlobalQuote(v);
      if (quote != null) {
        if (kDebugMode) debugPrint('AlphaVantage: matched $baseSymbol -> $v');
        return quote;
      }
    }
    if (kDebugMode) debugPrint('AlphaVantage: no match for $baseSymbol');
    return null;
  }

  Future<Quote?> _fetchGlobalQuote(String symbol) async {
    final url = Uri.parse(
        'https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=$symbol&apikey=$apiKey');

    final res = await http.get(url).timeout(Duration(seconds: 10));
    if (res.statusCode != 200) return null;

    final body = json.decode(res.body);

    if (body is Map && body.containsKey('Note')) {
      if (kDebugMode) debugPrint('AlphaVantage Note: ${body['Note']}');
      return null;
    }

    final global = (body is Map) ? (body['Global Quote'] as Map<String, dynamic>?) : null;
    if (global == null || global.isEmpty) {
      return null;
    }

    final sym = (global['01. symbol'] ?? symbol).toString();
    final priceStr = (global['05. price'] ?? '').toString();
    final changeStr = (global['09. change'] ?? '').toString();
    final pctStr = (global['10. change percent'] ?? '').toString().replaceAll('%', '');

    final price = double.tryParse(priceStr) ?? 0.0;
    final change = double.tryParse(changeStr) ?? 0.0;
    final pct = double.tryParse(pctStr) ?? 0.0;

    return Quote(
      symbol: sym.toUpperCase(),
      ltp: double.parse(price.toStringAsFixed(2)),
      change: double.parse(change.toStringAsFixed(2)),
      percent: double.parse(pct.toStringAsFixed(2)),
    );
  }
}



class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trading UI Demo',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        scaffoldBackgroundColor: Colors.grey[50],
        appBarTheme: AppBarTheme(
          elevation: 0,
          color: Colors.grey[50],
          centerTitle: false,
          titleTextStyle:
          TextStyle(color: Colors.black87, fontSize: 22, fontWeight: FontWeight.w700),
          iconTheme: IconThemeData(color: Colors.black54),
        ),
      ),
      home: MainShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainShell extends StatefulWidget {
  @override
  _MainShellState createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final pages = [
    WatchlistPage(),
    OrdersPage(),
    PortfolioPage(),
    BidsPage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    final titles = ['Watchlist', 'Orders', 'Portfolio', 'Bids', 'Profile'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_currentIndex]),
        actions: [
          IconButton(icon: Icon(Icons.shopping_cart_outlined), onPressed: () {}),
          IconButton(icon: Icon(Icons.keyboard_arrow_down), onPressed: () {}),
        ],
      ),
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.blue[800],
        unselectedItemColor: Colors.black54,
        showUnselectedLabels: true,
        onTap: (i) => setState(() => _currentIndex = i),
        items: [
          BottomNavigationBarItem(icon: Icon(Icons.bookmark), label: 'Watchlist'),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Orders'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2), label: 'Portfolio'),
          BottomNavigationBarItem(icon: Icon(Icons.gavel), label: 'Bids'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}


class WatchlistPage extends StatefulWidget {
  @override
  _WatchlistPageState createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _searchController = TextEditingController();
  final _filterKey = GlobalKey();

  final _tabs = ['Favorites', 'My list', 'Must watch', 'Laraib Choice'];

  @override
  void initState() {
    _tabController = TabController(length: _tabs.length, vsync: this);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    return Column(
      children: [
        Container(
          color: Colors.grey[50],
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: Colors.blue[800],
            unselectedLabelColor: Colors.black54,
            indicatorColor: Colors.blue[800],
            tabs: _tabs.map((t) => Tab(text: t)).toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 46,
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: Colors.black26),
                      SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(hintText: 'Search & add', border: InputBorder.none),
                          onSubmitted: (v) {
                            if (v.trim().isNotEmpty) {
                              Provider.of<AppState>(context, listen: false).addToWatchlist(v);
                              _searchController.clear();
                            }
                          },
                        ),
                      ),
                      Text('${app.watchlist.length}/100', style: TextStyle(color: Colors.black26, fontSize: 12))
                    ],
                  ),
                ),
              ),
              SizedBox(width: 10),
              InkWell(
                key: _filterKey,
                onTap: () {},
                child: Container(
                  height: 46,
                  width: 46,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 6)],
                  ),
                  child: Icon(Icons.tune, color: Colors.black54),
                ),
              )
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: app.watchlist.length,
            separatorBuilder: (_, __) => Divider(height: 1),
            itemBuilder: (context, index) {
              final symbol = app.watchlist[index];
              final q = app.getQuote(symbol);
              final changeColor = (q.percent >= 0) ? Colors.green[700] : Colors.red[700];
              return ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                title: Text(symbol, style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('NSE', style: TextStyle(color: Colors.black45)),
                trailing: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(q.ltp.toStringAsFixed(2),
                        style: TextStyle(fontSize: 16, color: changeColor, fontWeight: FontWeight.w700)),
                    SizedBox(height: 6),
                    Text(
                      '${q.change >= 0 ? '+' : ''}${q.change.toStringAsFixed(2)} (${q.percent >= 0 ? '+' : ''}${q.percent.toStringAsFixed(2)}%)',
                      style: TextStyle(color: Colors.black45, fontSize: 12),
                    ),
                  ],
                ),
                onTap: () => _showPlaceOrderDialog(context, symbol),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showPlaceOrderDialog(BuildContext context, String symbol) {
    showDialog(context: context, builder: (_) => PlaceOrderDialog(symbol: symbol));
  }
}

class OrdersPage extends StatefulWidget {
  @override
  _OrdersPageState createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> with TickerProviderStateMixin {
  final tabs = ['Open', 'Executed', 'GTT', 'Baskets'];


  static const double _actionHeight = 56.0;
  static const double _actionMargin = 12.0;

  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);


    final double bottomSafe = MediaQuery.of(context).padding.bottom;
    final double keyboardInset = MediaQuery.of(context).viewInsets.bottom;


    final double buttonBottomOffset = _actionMargin + (keyboardInset > 0 ? keyboardInset : bottomSafe);


    final double listBottomPadding = _actionHeight + _actionMargin * 2 + bottomSafe;

    return SafeArea(
      child: Stack(
        children: [

          Column(
            children: [

              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: tabs.map((t) {
                    final count = (t == 'Open')
                        ? app.orders.where((o) => o.status == 'OPEN').length
                        : (t == 'Executed')
                        ? app.orders.where((o) => o.status == 'EXECUTED').length
                        : 0;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: Chip(
                        backgroundColor: Colors.grey[100],
                        label: Row(
                          children: [
                            Text(t, style: TextStyle(fontWeight: FontWeight.w600)),
                            if (count > 0) ...[
                              SizedBox(width: 6),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.blue[50],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text('$count', style: TextStyle(color: Colors.blue[800])),
                              )
                            ],
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),


              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.only(bottom: listBottomPadding),
                  itemCount: app.orders.length,
                  separatorBuilder: (_, __) => Divider(height: 1),
                  itemBuilder: (context, idx) {
                    final o = app.orders[idx];
                    return ListTile(
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      leading: Container(
                        width: 56,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              decoration: BoxDecoration(
                                color: (o.side == OrderSide.buy) ? Colors.blue[50] : Colors.red[50],
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                o.side == OrderSide.buy ? 'BUY' : 'SELL',
                                style: TextStyle(
                                  color: o.side == OrderSide.buy ? Colors.blue[800] : Colors.red[800],
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            SizedBox(height: 8),
                            Text('0/${o.qty}', style: TextStyle(color: Colors.black54, fontSize: 12)),
                          ],
                        ),
                      ),
                      title: Text(o.symbol, style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${o.qty} @ ${o.price.toStringAsFixed(2)} • ${o.status}'),
                      
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min, 
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${o.createdAt.hour.toString().padLeft(2, '0')}:${o.createdAt.minute.toString().padLeft(2, '0')}:${o.createdAt.second.toString().padLeft(2, '0')}',
                            style: TextStyle(color: Colors.black45, fontSize: 12),
                          ),
                          SizedBox(height: 6),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey[200],
                              foregroundColor: Colors.black87,
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              minimumSize: Size(64, 32), 
                              elevation: 0,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap, 
                            ),
                            child: Text('OPEN', style: TextStyle(fontSize: 12)),
                            onPressed: () {},
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),

          Positioned(
            left: _actionMargin,
            right: _actionMargin,
            bottom: buttonBottomOffset,
            child: SizedBox(
              height: _actionHeight,
              child: ElevatedButton.icon(
                icon: Icon(Icons.add),
                label: Text('Place mock order'),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => showDialog(context: context, builder: (_) => PlaceOrderDialog()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class PortfolioPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final app = Provider.of<AppState>(context);
    double invested = 0.0;
    double current = 0.0;
    for (var h in app.holdings) {
      invested += h.avg * h.qty;
      final q = app.quotes[h.symbol.toUpperCase().replaceAll(' ', '')];
      final ltp = q?.ltp ?? h.avg;
      current += ltp * h.qty;
    }

    final pnl = current - invested;
    final pnlPercent = invested == 0 ? 0.0 : (pnl / invested) * 100;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Invested', style: TextStyle(color: Colors.black45)),
                            SizedBox(height: 6),
                            Text('₹${invested.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.w700)),
                          ])),
                      Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('Current', style: TextStyle(color: Colors.black45)),
                            SizedBox(height: 6),
                            Text('₹${current.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.w700)),
                          ])),
                    ],
                  ),
                  SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    child: Card(
                      color: Colors.white,
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('P&L', style: TextStyle(color: Colors.black54)),
                            Row(
                              children: [
                                Text('${pnl >= 0 ? '+' : ''}₹${pnl.toStringAsFixed(2)}',
                                    style: TextStyle(
                                        color: pnl >= 0 ? Colors.green[700] : Colors.red[700], fontWeight: FontWeight.w700)),
                                SizedBox(width: 8),
                                Container(
                                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                      color: pnl >= 0 ? Colors.green[50] : Colors.red[50], borderRadius: BorderRadius.circular(6)),
                                  child: Text('${pnlPercent >= 0 ? '+' : ''}${pnlPercent.toStringAsFixed(2)}%',
                                      style: TextStyle(
                                          color: pnl >= 0 ? Colors.green[700] : Colors.red[700], fontWeight: FontWeight.w700)),
                                )
                              ],
                            )
                          ],
                        ),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
            child: Row(children: [Icon(Icons.search, color: Colors.black26), SizedBox(width: 8), Chip(label: Text('Equity')), SizedBox(width: 8), Chip(label: Text('Family')), Spacer(), Icon(Icons.analytics, color: Colors.black26)])),
        Expanded(
          child: ListView.separated(
            itemCount: app.holdings.length,
            separatorBuilder: (_, __) => Divider(height: 1),
            itemBuilder: (context, idx) {
              final h = app.holdings[idx];
              final q = app.quotes[h.symbol.toUpperCase().replaceAll(' ', '')];
              final ltp = q?.ltp ?? h.avg;
              final changePct = q?.percent ?? 0.0;
              return ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                title: Text(h.symbol, style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Invested ${(h.avg * h.qty).toStringAsFixed(2)}'),
                trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${(ltp * h.qty).toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(height: 6),
                  Text('${changePct >= 0 ? '+' : ''}${changePct.toStringAsFixed(2)}%',
                      style: TextStyle(color: changePct >= 0 ? Colors.green[700] : Colors.red[700])),
                ]),
              );
            },
          ),
        )
      ],
    );
  }
}


class BidsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(child: Text('Bids / Auction (placeholder)'));
}

class ProfilePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(child: Text('Profile (placeholder)'));
}


class PlaceOrderDialog extends StatefulWidget {
  final String? symbol;
  PlaceOrderDialog({this.symbol});

  @override
  _PlaceOrderDialogState createState() => _PlaceOrderDialogState();
}

class _PlaceOrderDialogState extends State<PlaceOrderDialog> {
  late TextEditingController _symbolController;
  late TextEditingController _qtyController;
  late TextEditingController _priceController;
  OrderSide side = OrderSide.buy;

  @override
  void initState() {
    super.initState();
    _symbolController = TextEditingController(text: widget.symbol ?? '');
    _qtyController = TextEditingController(text: '1');
    _priceController = TextEditingController(text: '100.00');

    if (widget.symbol != null && widget.symbol!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final q = Provider.of<AppState>(context, listen: false).getQuote(widget.symbol!);
        if (q.ltp > 0) _priceController.text = q.ltp.toStringAsFixed(2);
      });
    }
  }

  @override
  void dispose() {
    _symbolController.dispose();
    _qtyController.dispose();
    _price_controller_dispose_safe();
    super.dispose();
  }


  void _price_controller_dispose_safe() {
    try {
      _priceController.dispose();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Place mock order'),
      content: SingleChildScrollView(
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(labelText: 'Symbol'),
              controller: _symbolController,
              onChanged: (v) => _symbolController.text = v.toUpperCase(),
            ),
            SizedBox(height: 8),
            Row(
              children: [
                ChoiceChip(label: Text('BUY'), selected: side == OrderSide.buy, onSelected: (_) => setState(() => side = OrderSide.buy)),
                SizedBox(width: 8),
                ChoiceChip(label: Text('SELL'), selected: side == OrderSide.sell, onSelected: (_) => setState(() => side = OrderSide.sell)),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: TextField(decoration: InputDecoration(labelText: 'Qty'), keyboardType: TextInputType.number, controller: _qtyController)),
                SizedBox(width: 12),
                Expanded(child: TextField(decoration: InputDecoration(labelText: 'Price'), keyboardType: TextInputType.numberWithOptions(decimal: true), controller: _priceController)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel')),
        ElevatedButton(
          child: Text('Place'),
          onPressed: () {
            final symbol = _symbolController.text.trim().toUpperCase();
            final qty = int.tryParse(_qtyController.text) ?? 1;
            final price = double.tryParse(_priceController.text) ?? 0.0;
            if (symbol.isEmpty) return;
            Provider.of<AppState>(context, listen: false).placeOrder(symbol: symbol, side: side, qty: qty, price: price);
            Navigator.pop(context);
          },
        )
      ],
    );
  }
}
