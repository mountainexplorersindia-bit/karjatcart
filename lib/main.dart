import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import 'firebase_options.dart';
import 'firebase_phone_auth_service.dart';
import 'complete_profile_screen.dart';

final List<Map<String, dynamic>> savedOrders = [];

const scheduleWindowDays = 7;

class DeliverySlot {
  final String id;
  final String dateKey;
  final String startTime;
  final String endTime;
  final int capacity;
  int bookedOrders;

  DeliverySlot({
    required this.id,
    required this.dateKey,
    required this.startTime,
    required this.endTime,
    this.capacity = 20,
    this.bookedOrders = 0,
  });

  int get remainingCapacity => capacity - bookedOrders;

  bool get isFull => bookedOrders >= capacity;
}

const _slotTimes = [
  ('8:00 AM', '10:00 AM'),
  ('10:00 AM', '12:00 PM'),
  ('12:00 PM', '2:00 PM'),
  ('2:00 PM', '4:00 PM'),
  ('4:00 PM', '6:00 PM'),
  ('6:00 PM', '8:00 PM'),
];

final Map<String, List<DeliverySlot>> deliverySlotsByDate = {};

String deliveryDateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

List<DeliverySlot> slotsForDate(DateTime date) {
  final dateKey = deliveryDateKey(date);
  return deliverySlotsByDate.putIfAbsent(
    dateKey,
    () => [
      for (var index = 0; index < _slotTimes.length; index++)
        DeliverySlot(
          id: '$dateKey-slot-$index',
          dateKey: dateKey,
          startTime: _slotTimes[index].$1,
          endTime: _slotTimes[index].$2,
        ),
    ],
  );
}

String formatDeliveryDate(DateTime date) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}';
}

DateTime? parseDeliveryDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

final List<Map<String, dynamic>> savedAddresses = [];
String currentCustomerName = '';
String currentCustomerMobile = '';

void saveCustomerAddress(Map<String, dynamic> address) {
  final addressCopy = Map<String, dynamic>.from(address);
  final addressId = addressCopy['id']?.toString().trim();
  if (addressId == null || addressId.isEmpty) {
    addressCopy['id'] = DateTime.now().microsecondsSinceEpoch.toString();
  }
  final existingIndex = savedAddresses.indexWhere(
    (saved) => saved['id']?.toString() == addressCopy['id']?.toString(),
  );

  if (existingIndex >= 0) {
    savedAddresses[existingIndex] = addressCopy;
  } else {
    savedAddresses.add(addressCopy);
  }
}

Future<Map<String, dynamic>> _addressWithVerifiedCustomerMobile(
  Map<String, dynamic> address,
  FirebasePhoneAuthService authService,
) async {
  final existingMobile = address['mobile']?.toString().trim() ?? '';
  if (existingMobile.isNotEmpty) return address;

  final verifiedMobile =
      await authService.getCurrentVerifiedMobileNumber() ?? '';
  if (verifiedMobile.trim().isEmpty) return address;
  return {...address, 'mobile': verifiedMobile.trim()};
}

const orderStatuses = [
  'Preparing Order',
  'Packed',
  'Delivery Partner Assigned',
  'Out for Delivery',
  'Delivered',
];

int orderStatusIndex(String status) {
  final index = orderStatuses.indexOf(status);
  return index < 0 ? 0 : index;
}

void updateOrderStatus(String orderId, String status) {
  if (!orderStatuses.contains(status)) return;

  for (final order in savedOrders) {
    if (order['orderId'] == orderId) {
      order['status'] = status;
      break;
    }
  }
}

class _ServiceableLocation {
  final String name;
  final double latitude;
  final double longitude;
  final String pincode;

  const _ServiceableLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.pincode,
  });
}

const _serviceableLocations = [
  _ServiceableLocation(
    name: 'Karjat',
    latitude: 18.9149,
    longitude: 73.32213,
    pincode: '410201',
  ),
  _ServiceableLocation(
    name: 'Neral',
    latitude: 19.02664,
    longitude: 73.31812,
    pincode: '410101',
  ),
  _ServiceableLocation(
    name: 'Kadav',
    latitude: 18.96292,
    longitude: 73.37442,
    pincode: '410201',
  ),
  _ServiceableLocation(
    name: 'Kashele',
    latitude: 19.01027,
    longitude: 73.42030,
    pincode: '410201',
  ),
];

const _serviceRadiusMeters = 10000.0;

_ServiceableLocation? _serviceableLocationForCoordinates(
  double latitude,
  double longitude, {
  String? pincode,
}) {
  for (final location in _serviceableLocations) {
    final distance = Geolocator.distanceBetween(
      latitude,
      longitude,
      location.latitude,
      location.longitude,
    );

    if (distance <= _serviceRadiusMeters) {
      return location;
    }
  }

  return null;
}

String _normalizedLocationText(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

_ServiceableLocation? _serviceableLocationForManualText(
  String text, {
  String? pincode,
}) {
  final normalizedText = _normalizedLocationText(text);
  final normalizedPincode = pincode?.trim() ?? '';

  for (final location in _serviceableLocations) {
    final matchesName = normalizedText.contains(
      _normalizedLocationText(location.name),
    );
    final matchesPincode =
        normalizedPincode.isEmpty || normalizedPincode == location.pincode;
    if (matchesName && matchesPincode) return location;
  }
  return null;
}

bool _isAddressServiceable(Map<String, dynamic> address) {
  final area = (address['area'] ?? '').toString().trim().toLowerCase();
  final pincode = (address['pincode'] ?? '').toString().trim();

  if (pincode == '410201' && area.contains('karjat')) return true;
  if (pincode == '410201' && area.contains('kadav')) return true;
  if (pincode == '410201' && area.contains('kashele')) return true;
  if (pincode == '410101' && area.contains('neral')) return true;
  return false;
}

String _formatOrderDateTime(DateTime dateTime) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');

  final hour =
      dateTime.hour == 0
          ? 12
          : dateTime.hour > 12
          ? dateTime.hour - 12
          : dateTime.hour;
  final period = dateTime.hour >= 12 ? 'PM' : 'AM';

  return '${twoDigits(dateTime.day)}/${twoDigits(dateTime.month)}/${dateTime.year} '
      '${twoDigits(hour)}:${twoDigits(dateTime.minute)} $period';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const KarjatGroceryApp());
}

class KarjatGroceryApp extends StatelessWidget {
  const KarjatGroceryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Karjat Cart',
      theme: ThemeData(
        primarySwatch: Colors.green,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const SplashScreen(),
    );
  }
}

class Product {
  final String name;
  final String brand;
  final double price;
  final IconData icon;
  final String category;

  const Product({
    required this.name,
    required this.brand,
    required this.price,
    required this.icon,
    this.category = 'Grocery',
  });
}

class CategoryDefinition {
  final String name;
  final IconData icon;

  const CategoryDefinition({required this.name, required this.icon});
}

const categoryDefinitions = [
  CategoryDefinition(name: 'Grocery', icon: Icons.shopping_basket),
  CategoryDefinition(name: 'Dairy', icon: Icons.local_drink),
  CategoryDefinition(name: 'Snacks', icon: Icons.fastfood),
  CategoryDefinition(name: 'Beverages', icon: Icons.local_cafe),
  CategoryDefinition(name: 'Cleaning', icon: Icons.cleaning_services),
  CategoryDefinition(name: 'Personal Care', icon: Icons.spa),
  CategoryDefinition(name: 'Staples', icon: Icons.inventory_2),
  CategoryDefinition(name: 'Household', icon: Icons.home_outlined),
];

final List<Product> allProducts = [
  Product(
    name: 'Wheat Atta 5 kg',
    brand: 'Aashirvaad',
    price: 285,
    icon: Icons.grain,
    category: 'Grocery',
  ),
  Product(
    name: 'Regular Rice 5 kg',
    brand: 'India Gate',
    price: 420,
    icon: Icons.rice_bowl,
    category: 'Grocery',
  ),
  Product(
    name: 'Sunflower Oil 1 L',
    brand: 'Fortune',
    price: 145,
    icon: Icons.local_drink,
    category: 'Beverages',
  ),
  Product(
    name: 'Tea 250 g',
    brand: 'Tata Tea',
    price: 125,
    icon: Icons.coffee,
    category: 'Beverages',
  ),
  Product(
    name: 'Rice',
    brand: 'KarjatCart',
    price: 60,
    icon: Icons.rice_bowl,
    category: 'Grocery',
  ),
  Product(
    name: 'Wheat Flour',
    brand: 'KarjatCart',
    price: 50,
    icon: Icons.grain,
    category: 'Grocery',
  ),
  Product(
    name: 'Sugar',
    brand: 'KarjatCart',
    price: 45,
    icon: Icons.shopping_bag,
    category: 'Grocery',
  ),
  Product(
    name: 'Toor Dal',
    brand: 'KarjatCart',
    price: 120,
    icon: Icons.spa,
    category: 'Grocery',
  ),
];

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const SplashNextScreen()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff4fff7),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),

            // Logo-style illustration
            Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                color: const Color(0xffffc928),
                borderRadius: BorderRadius.circular(90),
              ),
              child: Image.asset(
                'assets/images/karjatcart_logo.png',
                width: 280,
                height: 280,
                fit: BoxFit.contain,
              ),
            ),

            const SizedBox(height: 25),

            const Text(
              'KarjatCart',
              style: TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.bold,
                color: Color(0xff075b38),
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Your Local Basket, Delivered.',
              style: TextStyle(fontSize: 17, color: Color(0xff245b42)),
            ),

            const SizedBox(height: 8),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.location_on, color: Color(0xff075b38), size: 20),
                SizedBox(width: 5),
                Text(
                  'KARJAT',
                  style: TextStyle(
                    fontSize: 15,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff075b38),
                  ),
                ),
              ],
            ),

            const Spacer(),

            const Text(
              'Welcome to KarjatCart',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
                color: Color(0xff075b38),
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Fresh groceries from Karjat, delivered to your doorstep.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, color: Colors.grey),
            ),

            const Spacer(),

            const Padding(
              padding: EdgeInsets.only(bottom: 25),
              child: Text(
                'Loading your local store...',
                style: TextStyle(fontSize: 14, color: Color(0xff075b38)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SplashNextScreen extends StatefulWidget {
  const SplashNextScreen({super.key});

  @override
  State<SplashNextScreen> createState() => _SplashNextScreenState();
}

class _SplashNextScreenState extends State<SplashNextScreen> {
  final TextEditingController mobileController = TextEditingController();
  final FirebasePhoneAuthService authService = FirebasePhoneAuthService();
  bool isSendingOtp = false;
  bool isGoogleSigningIn = false;
  bool googlePhoneVerificationRequired = false;

  Future<void> generateOtp() async {
    final mobile = mobileController.text.trim();
    if (FirebasePhoneAuthService.normalizeIndianPhoneNumber(mobile) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid 10-digit mobile number'),
        ),
      );
      return;
    }

    setState(() => isSendingOtp = true);
    try {
      if (googlePhoneVerificationRequired) {
        var otpRouteOpened = false;
        void openGoogleOtp({bool automaticallyVerified = false}) {
          final replaceCurrentRoute = otpRouteOpened;
          otpRouteOpened = true;
          if (!mounted) return;
          final route = MaterialPageRoute(
            builder:
                (context) => OtpScreen(
                  mobileNumber: mobile,
                  authService: authService,
                  googlePhoneVerification: true,
                  googlePhoneAlreadyVerified: automaticallyVerified,
                ),
          );
          if (replaceCurrentRoute) {
            Navigator.pushReplacement(context, route);
          } else {
            Navigator.push(context, route);
          }
        }

        await authService.sendGooglePhoneVerificationOtp(
          mobile,
          onCodeSent: () {
            if (!otpRouteOpened) openGoogleOtp();
          },
          onAutoVerified: () => openGoogleOtp(automaticallyVerified: true),
          onAutoVerificationError: (exception) {
            if (!mounted) return;
            if (!authService.hasPendingGoogleCredential) {
              setState(() => googlePhoneVerificationRequired = false);
            }
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
          },
        );
      } else {
        await authService.sendOtp(
          mobile,
          onProfilePersistenceError: (exception) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
          },
          onCodeSent: () {
            if (!mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (context) => OtpScreen(
                      mobileNumber: mobile,
                      authService: authService,
                    ),
              ),
            );
          },
        );
      }
    } on FirebasePhoneAuthException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } finally {
      if (mounted) setState(() => isSendingOtp = false);
    }
  }

  Future<void> signInWithGoogle() async {
    if (isGoogleSigningIn) return;
    setState(() => isGoogleSigningIn = true);
    try {
      final googleResult = await authService.signInWithGoogle();
      if (!mounted) return;
      if (googleResult == null) {
        setState(() => googlePhoneVerificationRequired = false);
        return;
      }
      if (googleResult == GoogleSignInResult.directLogin) {
        final currentUser = authService.currentUser;
        if (currentUser?.phoneNumber?.trim().isNotEmpty != true) {
          throw const FirebaseGoogleSignInException(
            'Google sign-in could not be verified. Please try again.',
          );
        }
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (context) => OtpScreen(
                  mobileNumber: currentUser!.phoneNumber!,
                  authService: authService,
                  googleAuthenticated: true,
                ),
          ),
        );
      } else {
        setState(() => googlePhoneVerificationRequired = true);
      }
    } on FirebaseGoogleSignInException catch (exception) {
      if (!mounted) return;
      if (!authService.hasPendingGoogleCredential) {
        setState(() => googlePhoneVerificationRequired = false);
      }
      final details = exception.code == null ? '' : ' (${exception.code})';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${exception.message}$details')));
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      if (!authService.hasPendingGoogleCredential) {
        setState(() => googlePhoneVerificationRequired = false);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } on FirebasePhoneAuthException catch (exception) {
      if (!mounted) return;
      if (!authService.hasPendingGoogleCredential) {
        setState(() => googlePhoneVerificationRequired = false);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } finally {
      if (mounted) setState(() => isGoogleSigningIn = false);
    }
  }

  @override
  void dispose() {
    authService.clearPendingGoogleSignIn();
    mobileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child:
            isGoogleSigningIn
                ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xff079447)),
                      SizedBox(height: 16),
                      Text('Signing in with Google...'),
                    ],
                  ),
                )
                : SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 25),

                        // KarjatCart Logo
                        Image.asset(
                          'assets/images/karjatcart_logo.png',
                          width: 210,
                          height: 210,
                          fit: BoxFit.contain,
                        ),

                        const SizedBox(height: 5),

                        // Welcome text
                        const Text(
                          'Welcome to KarjatCart',
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF075B3A),
                          ),
                          textAlign: TextAlign.center,
                        ),

                        const SizedBox(height: 8),

                        const Text(
                          'Fresh groceries from Karjat, delivered to your doorstep.',
                          style: TextStyle(fontSize: 15, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),

                        if (googlePhoneVerificationRequired) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Verify a mobile number for your Google account to continue.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xff075b38),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],

                        const SizedBox(height: 32),

                        // Mobile number field
                        Container(
                          height: 58,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(
                                      color: Colors.grey.shade300,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      '🇮🇳',
                                      style: TextStyle(fontSize: 22),
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      '+91',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(Icons.keyboard_arrow_down, size: 20),
                                  ],
                                ),
                              ),

                              Expanded(
                                child: TextField(
                                  controller: mobileController,
                                  keyboardType: TextInputType.phone,
                                  maxLength: 10,
                                  decoration: const InputDecoration(
                                    hintText: 'Enter mobile number',
                                    hintStyle: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 16,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    counterText: '',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),

                        // Send OTP button
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            onPressed: isSendingOtp ? null : generateOtp,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF079447),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  isSendingOtp
                                      ? 'Sending OTP...'
                                      : googlePhoneVerificationRequired
                                      ? 'Verify Phone Number'
                                      : 'Send OTP',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Icon(Icons.arrow_forward, size: 25),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 28),

                        // OR divider
                        Row(
                          children: [
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 14),
                              child: Text(
                                'OR CONTINUE WITH',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(color: Colors.grey.shade300),
                            ),
                          ],
                        ),

                        const SizedBox(height: 18),

                        // Google and Apple
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed:
                                    isGoogleSigningIn ? null : signInWithGoogle,
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 52),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  side: BorderSide(color: Colors.grey.shade300),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (isGoogleSigningIn)
                                      SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.blue,
                                        ),
                                      )
                                    else
                                      Text(
                                        'G',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.blue,
                                        ),
                                      ),
                                    SizedBox(width: 10),
                                    Text(
                                      isGoogleSigningIn
                                          ? 'Connecting...'
                                          : 'Google',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: Colors.black,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(width: 12),

                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {},
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 52),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  side: BorderSide(color: Colors.grey.shade300),
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.apple,
                                      size: 24,
                                      color: Colors.black,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Apple',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: Colors.black,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 25),

                        // Karjat landscape illustration
                        Image.asset(
                          'assets/images/karjat_landscape.png',
                          width: double.infinity,
                          height: 190,
                          fit: BoxFit.cover,
                        ),

                        const SizedBox(height: 20),

                        // Bottom message
                        const Text(
                          'Good Food\nBrighter Days\nKarjat Always',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF075B3A),
                            height: 1.25,
                          ),
                        ),

                        const SizedBox(height: 25),
                      ],
                    ),
                  ),
                ),
      ),
    );
  }
}

class _LocationResult {
  final bool isServiceable;
  final Map<String, dynamic> address;

  const _LocationResult({required this.isServiceable, required this.address});
}

_ServiceableLocation? _serviceableLocationForPlace(
  Placemark place,
  double latitude,
  double longitude, {
  String? requiredPincode,
}) {
  return _serviceableLocationForCoordinates(
    latitude,
    longitude,
    pincode: requiredPincode ?? (place.postalCode ?? '').trim(),
  );
}

Map<String, dynamic> _addressFromPlace(
  Placemark place, {
  required String mobileNumber,
  double? latitude,
  double? longitude,
}) {
  return {
    'name': '',
    'mobile': mobileNumber,
    'house': [place.name, place.street]
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .join(', '),
    'area': [place.subLocality, place.locality]
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .join(', '),
    'pincode': place.postalCode ?? '',
    'landmark': [
      place.administrativeArea,
      place.postalCode,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(', '),
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
  };
}

class OtpScreen extends StatefulWidget {
  final String mobileNumber;
  final FirebasePhoneAuthService authService;
  final bool googleAuthenticated;
  final bool googlePhoneVerification;
  final bool googlePhoneAlreadyVerified;

  const OtpScreen({
    super.key,
    required this.mobileNumber,
    required this.authService,
    this.googleAuthenticated = false,
    this.googlePhoneVerification = false,
    this.googlePhoneAlreadyVerified = false,
  });

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final TextEditingController otpController = TextEditingController();
  bool isVerifying = false;
  bool isResending = false;
  bool isRequestingLocationPermission = false;

  @override
  void initState() {
    super.initState();
    if (widget.googleAuthenticated || widget.googlePhoneAlreadyVerified) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) verifyOtp();
      });
    }
  }

  void _logLoginStep(String marker, Stopwatch stopwatch, {String? detail}) {
    debugPrint(
      '$marker elapsedMs=${stopwatch.elapsedMilliseconds}'
      '${detail == null ? '' : ' $detail'}',
    );
  }

  void _logLoginException(
    String marker,
    Stopwatch stopwatch,
    Object exception,
    StackTrace stackTrace,
  ) {
    debugPrint(
      '$marker elapsedMs=${stopwatch.elapsedMilliseconds} exception=$exception',
    );
    debugPrintStack(stackTrace: stackTrace);
  }

  Future<void> verifyOtp() async {
    if (isVerifying) return;
    setState(() => isVerifying = true);
    final loginStopwatch = Stopwatch()..start();
    try {
      if (widget.googlePhoneVerification) {
        if (!widget.googlePhoneAlreadyVerified) {
          try {
            await widget.authService.verifyGooglePhoneOtp(
              otpController.text.trim(),
            );
          } on FirebaseCustomerProfileException catch (exception, stackTrace) {
            _logLoginException(
              'LOGIN STEP: GOOGLE PHONE PROFILE WRITE ERROR',
              loginStopwatch,
              exception,
              stackTrace,
            );
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
            if (!widget.authService.hasPendingGoogleCredential) {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (context) => const SplashNextScreen(),
                ),
                (route) => false,
              );
            }
            return;
          } on FirebasePhoneAuthException catch (exception, stackTrace) {
            _logLoginException(
              'LOGIN STEP: GOOGLE PHONE LINK ERROR',
              loginStopwatch,
              exception,
              stackTrace,
            );
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
            if (!widget.authService.hasPendingGoogleCredential) {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(
                  builder: (context) => const SplashNextScreen(),
                ),
                (route) => false,
              );
            }
            return;
          }
        }
      } else if (!widget.googleAuthenticated) {
        try {
          await widget.authService.verifyOtp(
            otpController.text.trim(),
            diagnosticStopwatch: loginStopwatch,
          );
        } on FirebaseCustomerProfileException catch (exception, stackTrace) {
          _logLoginException(
            'LOGIN STEP: PROFILE UPSERT ERROR',
            loginStopwatch,
            exception,
            stackTrace,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(exception.message)));
          return;
        } on FirebasePhoneAuthException catch (exception, stackTrace) {
          _logLoginException(
            'LOGIN STEP: OTP CONFIRM ERROR',
            loginStopwatch,
            exception,
            stackTrace,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(exception.debugMessage)));
          return;
        } catch (exception, stackTrace) {
          _logLoginException(
            'LOGIN STEP: OTP CONFIRM ERROR',
            loginStopwatch,
            exception,
            stackTrace,
          );
          rethrow;
        }
      }

      final firebaseUser = FirebaseAuth.instance.currentUser;
      if (firebaseUser == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to complete authentication.')),
        );
        return;
      }

      Map<String, dynamic>? customerProfile;
      var profileReadSucceeded = true;
      _logLoginStep('LOGIN STEP: PROFILE READ START', loginStopwatch);
      try {
        customerProfile = await widget.authService.getCurrentCustomerProfile();
        _logLoginStep('LOGIN STEP: PROFILE READ COMPLETE', loginStopwatch);
      } on FirebaseCustomerProfileException catch (exception, stackTrace) {
        _logLoginException(
          'LOGIN STEP: PROFILE READ ERROR',
          loginStopwatch,
          exception,
          stackTrace,
        );
        profileReadSucceeded = false;
        debugPrint('CUSTOMER PROFILE READ FALLBACK: ${exception.message}');
      } catch (exception, stackTrace) {
        _logLoginException(
          'LOGIN STEP: PROFILE READ ERROR',
          loginStopwatch,
          exception,
          stackTrace,
        );
        profileReadSucceeded = false;
      }

      if (!profileReadSucceeded) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your account was authenticated, but your customer profile could not be loaded. Please try again.',
            ),
          ),
        );
        return;
      }

      final needsProfileCompletion =
          profileReadSucceeded && customerProfile?['profileCompleted'] != true;
      var customerName = customerProfile?['fullName']?.toString() ?? '';
      currentCustomerName = customerName;
      currentCustomerMobile = widget.mobileNumber;

      if (needsProfileCompletion) {
        if (!mounted) return;
        _logLoginStep('LOGIN STEP: NAVIGATION START', loginStopwatch);
        final profileRoute = Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder:
                (context) => CompleteProfileScreen(
                  authService: widget.authService,
                  initialCustomerProfile: customerProfile ?? const {},
                  onLogout: () async {
                    await FirebaseAuth.instance.signOut();
                    currentCustomerName = '';
                    currentCustomerMobile = '';
                    savedAddresses.clear();
                    if (!mounted) return;
                    Navigator.pushAndRemoveUntil(
                      this.context,
                      MaterialPageRoute(
                        builder: (context) => const SplashNextScreen(),
                      ),
                      (route) => false,
                    );
                  },
                ),
          ),
        );
        _logLoginStep('LOGIN STEP: NAVIGATION COMPLETE', loginStopwatch);
        late final String? completedCustomerName;
        try {
          completedCustomerName = await profileRoute;
        } catch (exception, stackTrace) {
          _logLoginException(
            'LOGIN STEP: NAVIGATION ERROR',
            loginStopwatch,
            exception,
            stackTrace,
          );
          rethrow;
        }
        if (!mounted || completedCustomerName == null) return;
        customerName = completedCustomerName;
        currentCustomerName = customerName;
      }

      // Use GPS only to determine the customer's current serviceability.
      _logLoginStep('LOGIN STEP: LOCATION START', loginStopwatch);
      late final _LocationResult? location;
      try {
        location = await _getCurrentLocation(loginStopwatch);
        _logLoginStep('LOGIN STEP: LOCATION COMPLETE', loginStopwatch);
      } catch (exception, stackTrace) {
        _logLoginException(
          'LOGIN STEP: LOCATION ERROR',
          loginStopwatch,
          exception,
          stackTrace,
        );
        rethrow;
      }

      if (!mounted) return;

      var customerAddresses = <Map<String, dynamic>>[];
      String? defaultAddressId;
      try {
        final addressData = await widget.authService.loadCustomerAddressData();
        customerAddresses =
            (addressData['addresses'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map((address) => Map<String, dynamic>.from(address))
                .toList();
        defaultAddressId = addressData['defaultAddressId']?.toString();
        savedAddresses
          ..clear()
          ..addAll(customerAddresses.map(Map<String, dynamic>.from));
      } on FirebaseCustomerProfileException catch (exception, stackTrace) {
        _logLoginException(
          'LOGIN STEP: SAVED ADDRESSES READ ERROR',
          loginStopwatch,
          exception,
          stackTrace,
        );
      }

      Map<String, dynamic>? defaultAddress;
      var defaultAddressIsInvalid = false;
      if (defaultAddressId != null) {
        for (final address in customerAddresses) {
          if (address['id']?.toString() == defaultAddressId) {
            if (_isAddressServiceable(address)) {
              defaultAddress = address;
            } else {
              defaultAddressIsInvalid = true;
            }
            break;
          }
        }
      }

      if (needsProfileCompletion) {
        _logLoginStep('LOGIN STEP: NAVIGATION START', loginStopwatch);
        final address = await Navigator.push<Map<String, dynamic>>(
          context,
          MaterialPageRoute(
            builder:
                (context) => AddressScreen(
                  initialAddress:
                      location?.isServiceable == true
                          ? location!.address
                          : null,
                  authService: widget.authService,
                  customerName: customerName,
                  mobileNumber: widget.mobileNumber,
                  returnAddress: true,
                  currentLocationServiceable: location?.isServiceable,
                  currentLocationArea: location?.address['area']?.toString(),
                ),
          ),
        );
        _logLoginStep('LOGIN STEP: NAVIGATION COMPLETE', loginStopwatch);
        if (!mounted || address == null) return;
        _logLoginStep('LOGIN STEP: NAVIGATION START', loginStopwatch);
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (context) => HomeScreen(
                  authService: widget.authService,
                  customerName: customerName,
                  mobileNumber: widget.mobileNumber,
                  deliveryAddress: address,
                  currentLocationServiceable: location?.isServiceable,
                  currentLocationArea: location?.address['area']?.toString(),
                ),
          ),
        );
        _logLoginStep('LOGIN STEP: NAVIGATION COMPLETE', loginStopwatch);
        return;
      }

      _logLoginStep('LOGIN STEP: NAVIGATION START', loginStopwatch);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder:
              (context) => HomeScreen(
                authService: widget.authService,
                customerName: customerName,
                mobileNumber: widget.mobileNumber,
                deliveryAddress: defaultAddress,
                defaultAddressIsInvalid: defaultAddressIsInvalid,
                currentLocationServiceable: location?.isServiceable,
                currentLocationArea: location?.address['area']?.toString(),
              ),
        ),
      );
      _logLoginStep('LOGIN STEP: NAVIGATION COMPLETE', loginStopwatch);
    } finally {
      if (mounted) setState(() => isVerifying = false);
    }
  }

  Future<void> resendOtp() async {
    if (isVerifying) return;
    setState(() => isResending = true);
    try {
      if (widget.googlePhoneVerification) {
        await widget.authService.sendGooglePhoneVerificationOtp(
          widget.mobileNumber,
          onCodeSent: () {},
          onAutoVerified: () {
            if (!mounted) return;
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder:
                    (context) => OtpScreen(
                      mobileNumber: widget.mobileNumber,
                      authService: widget.authService,
                      googlePhoneVerification: true,
                      googlePhoneAlreadyVerified: true,
                    ),
              ),
            );
          },
          onAutoVerificationError: (exception) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
          },
        );
      } else {
        await widget.authService.sendOtp(
          widget.mobileNumber,
          onProfilePersistenceError: (exception) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(exception.message)));
          },
          onCodeSent: () {},
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A new OTP has been sent.')));
    } on FirebasePhoneAuthException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } finally {
      if (mounted) setState(() => isResending = false);
    }
  }

  Future<_LocationResult?> _getCurrentLocation(Stopwatch loginStopwatch) async {
    _logLoginStep('LOGIN STEP: LOCATION SERVICE CHECK START', loginStopwatch);
    final locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    _logLoginStep(
      'LOGIN STEP: LOCATION SERVICE CHECK COMPLETE',
      loginStopwatch,
    );
    if (!locationServiceEnabled) {
      return null;
    }

    late LocationPermission permission;
    try {
      _logLoginStep(
        'LOGIN STEP: LOCATION PERMISSION CHECK START',
        loginStopwatch,
      );
      permission = await Geolocator.checkPermission();
      _logLoginStep(
        'LOGIN STEP: LOCATION PERMISSION CHECK COMPLETE',
        loginStopwatch,
      );
      if (permission == LocationPermission.denied) {
        _logLoginStep(
          'LOGIN STEP: LOCATION PERMISSION REQUEST START',
          loginStopwatch,
        );
        if (mounted) {
          setState(() => isRequestingLocationPermission = true);
        }
        try {
          permission = await Geolocator.requestPermission().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              debugPrint('LOCATION PERMISSION REQUEST TIMEOUT');
              return LocationPermission.denied;
            },
          );
          _logLoginStep(
            'LOGIN STEP: LOCATION PERMISSION REQUEST COMPLETE',
            loginStopwatch,
          );
        } finally {
          if (mounted) {
            setState(() => isRequestingLocationPermission = false);
          }
        }
      }
    } catch (exception, stackTrace) {
      _logLoginException(
        'LOGIN STEP: LOCATION PERMISSION ERROR',
        loginStopwatch,
        exception,
        stackTrace,
      );
      return null;
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      _logLoginStep('LOGIN STEP: LOCATION POSITION START', loginStopwatch);
      final position = await Geolocator.getCurrentPosition();
      _logLoginStep('LOGIN STEP: LOCATION POSITION COMPLETE', loginStopwatch);
      final serviceableLocation = _serviceableLocationForCoordinates(
        position.latitude,
        position.longitude,
      );
      if (serviceableLocation == null) {
        return const _LocationResult(isServiceable: false, address: {});
      }

      _logLoginStep(
        'LOGIN STEP: LOCATION GEOCODING START',
        loginStopwatch,
        detail: 'reverse geocoding skipped; using coordinate match',
      );
      final address = {
        'name': '',
        'mobile': widget.mobileNumber,
        'house': '',
        'area': serviceableLocation.name,
        'pincode': serviceableLocation.pincode,
        'landmark': '${serviceableLocation.name}, Maharashtra',
        'latitude': position.latitude,
        'longitude': position.longitude,
      };
      _logLoginStep(
        'LOGIN STEP: LOCATION GEOCODING COMPLETE',
        loginStopwatch,
        detail: 'matched-location fallback constructed',
      );

      return _LocationResult(isServiceable: true, address: address);
    } catch (exception, stackTrace) {
      _logLoginException(
        'LOGIN STEP: LOCATION POSITION ERROR',
        loginStopwatch,
        exception,
        stackTrace,
      );
      return null;
    }
  }

  @override
  void dispose() {
    if (widget.googlePhoneVerification) {
      widget.authService.clearPendingGoogleSignIn();
    }
    otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.googleAuthenticated || widget.googlePhoneAlreadyVerified) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xff079447)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 25),

              // Back button
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: () {
                    if (widget.googlePhoneVerification) {
                      widget.authService.clearPendingGoogleSignIn();
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SplashNextScreen(),
                        ),
                        (route) => false,
                      );
                      return;
                    }
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.arrow_back, size: 26),
                ),
              ),

              const SizedBox(height: 5),

              // Logo
              Image.asset(
                'assets/images/karjatcart_logo.png',
                width: 150,
                height: 150,
                fit: BoxFit.contain,
              ),

              const SizedBox(height: 10),

              Text(
                widget.googlePhoneVerification
                    ? 'Verify your phone for Google'
                    : 'Verify your mobile number',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF075B3A),
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 10),

              Text(
                widget.googlePhoneVerification
                    ? 'We sent a 6-digit OTP to\n+91 ${widget.mobileNumber}'
                    : 'We sent a 6-digit OTP to\n+91 ${widget.mobileNumber}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                  height: 1.5,
                ),
              ),

              const SizedBox(height: 35),

              // OTP field
              Container(
                height: 60,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TextField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                  decoration: const InputDecoration(
                    hintText: '------',
                    hintStyle: TextStyle(color: Colors.grey, letterSpacing: 6),
                    border: InputBorder.none,
                    counterText: '',
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'Enter the 6-digit OTP sent by Firebase',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),

              const SizedBox(height: 25),

              // Verify button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: isVerifying ? null : verifyOtp,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF079447),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        isRequestingLocationPermission
                            ? 'Requesting location permission...'
                            : isVerifying
                            ? 'Verifying...'
                            : 'Verify & Continue',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(width: 12),
                      if (isRequestingLocationPermission)
                        const SizedBox.square(
                          dimension: 19,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      else
                        const Icon(Icons.arrow_forward, size: 24),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // Resend OTP
              TextButton(
                onPressed: isResending || isVerifying ? null : resendOtp,
                child: const Text(
                  'Resend OTP',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0xFF075B3A),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              const SizedBox(height: 25),

              // Landscape
              Image.asset(
                'assets/images/karjat_landscape.png',
                width: double.infinity,
                height: 150,
                fit: BoxFit.cover,
              ),

              const SizedBox(height: 20),

              const Text(
                'Your Local Basket, Delivered.',
                style: TextStyle(fontSize: 15, color: Colors.grey),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class LocationSelectionScreen extends StatefulWidget {
  final String mobileNumber;
  final String message;

  const LocationSelectionScreen({
    super.key,
    required this.mobileNumber,
    required this.message,
  });

  @override
  State<LocationSelectionScreen> createState() =>
      _LocationSelectionScreenState();
}

class _LocationSelectionScreenState extends State<LocationSelectionScreen> {
  final locationController = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    locationController.dispose();
    super.dispose();
  }

  Future<void> findLocation() async {
    final query = locationController.text.trim();
    if (query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your area, city, or PIN code.')),
      );
      return;
    }

    setState(() => isLoading = true);
    try {
      final manualLocation = _serviceableLocationForManualText(query);
      if (manualLocation != null) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (context) => AddressScreen(
                  initialAddress: {
                    'mobile': widget.mobileNumber,
                    'area': manualLocation.name,
                    'pincode': manualLocation.pincode,
                    'landmark': '${manualLocation.name}, Maharashtra',
                  },
                ),
          ),
        );
        return;
      }

      final locations = await locationFromAddress(query);
      for (final location in locations) {
        final placemarks = await placemarkFromCoordinates(
          location.latitude,
          location.longitude,
        );
        if (placemarks.isNotEmpty &&
            _serviceableLocationForPlace(
                  placemarks.first,
                  location.latitude,
                  location.longitude,
                ) !=
                null) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder:
                  (context) => AddressScreen(
                    initialAddress: _addressFromPlace(
                      placemarks.first,
                      mobileNumber: widget.mobileNumber,
                      latitude: location.latitude,
                      longitude: location.longitude,
                    ),
                  ),
            ),
          );
          return;
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not delivering in your locality.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location not found. Try: Karjat, Maharashtra.'),
        ),
      );
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose delivery location')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 20),
            TextField(
              controller: locationController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => findLocation(),
              decoration: const InputDecoration(
                labelText: 'Enter area, city, or PIN code',
                hintText: 'Example: Karjat, Maharashtra',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: isLoading ? null : findLocation,
                child: Text(isLoading ? 'Checking...' : 'Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final String? serviceabilityMessage;
  final Map<String, dynamic>? deliveryAddress;
  final String? mobileNumber;
  final String? customerName;
  final FirebasePhoneAuthService? authService;
  final bool? currentLocationServiceable;
  final String? currentLocationArea;
  final bool defaultAddressIsInvalid;

  const HomeScreen({
    super.key,
    this.serviceabilityMessage,
    this.deliveryAddress,
    this.mobileNumber,
    this.customerName,
    this.authService,
    this.currentLocationServiceable,
    this.currentLocationArea,
    this.defaultAddressIsInvalid = false,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<Product> products = allProducts;
  final TextEditingController searchController = TextEditingController();
  late final FirebasePhoneAuthService _authService;

  final Map<String, int> cart = {};
  final ValueNotifier<int> cartRevision = ValueNotifier(0);
  Map<String, dynamic>? confirmedAddress;
  bool _isLoadingAddresses = false;
  String? _addressLoadError;
  bool _defaultAddressIsInvalid = false;

  List<Product> get searchResults {
    final query = searchController.text.trim().toLowerCase();
    if (query.isEmpty) return products;

    return products
        .where(
          (product) =>
              product.name.toLowerCase().contains(query) ||
              product.brand.toLowerCase().contains(query) ||
              product.category.toLowerCase().contains(query),
        )
        .toList();
  }

  Map<String, dynamic>? get deliveryAddress => confirmedAddress;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? FirebasePhoneAuthService();
    confirmedAddress = widget.deliveryAddress;
    currentCustomerMobile =
        widget.mobileNumber ??
        widget.deliveryAddress?['mobile']?.toString() ??
        '';
    currentCustomerName =
        widget.customerName ??
        widget.deliveryAddress?['name']?.toString() ??
        '';
    _defaultAddressIsInvalid = widget.defaultAddressIsInvalid;
    if (confirmedAddress != null) saveCustomerAddress(confirmedAddress!);
    _loadCustomerAddresses();
  }

  Future<void> _loadCustomerAddresses() async {
    if (mounted) setState(() => _isLoadingAddresses = true);
    try {
      final addressData = await _authService.loadCustomerAddressData();
      final addresses =
          (addressData['addresses'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((address) => Map<String, dynamic>.from(address))
              .toList();
      final defaultId = addressData['defaultAddressId']?.toString();
      Map<String, dynamic>? defaultAddress;
      var invalidDefault = false;
      if (defaultId != null) {
        for (final address in addresses) {
          if (address['id']?.toString() == defaultId) {
            if (_isAddressServiceable(address)) {
              defaultAddress = address;
            } else {
              invalidDefault = true;
            }
            break;
          }
        }
      }

      savedAddresses
        ..clear()
        ..addAll(addresses.map(Map<String, dynamic>.from));
      if (!mounted) return;
      setState(() {
        if (confirmedAddress == null && defaultAddress != null) {
          confirmedAddress = defaultAddress;
        }
        _defaultAddressIsInvalid = invalidDefault;
        _addressLoadError = null;
      });
    } on FirebaseCustomerProfileException catch (exception) {
      if (mounted) setState(() => _addressLoadError = exception.message);
    } finally {
      if (mounted) setState(() => _isLoadingAddresses = false);
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    cartRevision.dispose();
    super.dispose();
  }

  int get cartItemCount {
    return cart.values.fold(0, (sum, quantity) => sum + quantity);
  }

  void addToCart(Product product) {
    if (deliveryAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Select a serviceable delivery address before adding items.',
          ),
        ),
      );
      unawaited(chooseDeliveryAddress());
      return;
    }

    setState(() {
      cart[product.name] = (cart[product.name] ?? 0) + 1;
    });
    cartRevision.value++;
    print('CART UPDATED: $cart');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${product.name} added to cart'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> openCart() async {
    if (deliveryAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a serviceable delivery address first.'),
        ),
      );
      unawaited(chooseDeliveryAddress());
      return;
    }

    late final Map<String, dynamic> checkoutAddress;
    try {
      checkoutAddress = await _addressWithVerifiedCustomerMobile(
        deliveryAddress!,
        _authService,
      );
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
      return;
    }
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => CartScreen(
              products: products,
              cart: cart,
              initialAddress: checkoutAddress,
              onCartChanged: () {
                setState(() {});
                cartRevision.value++;
              },
            ),
      ),
    );
  }

  void openCategory(String category) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => ProductListScreen(
              categoryName: category,
              onAddToCart: addToCart,
              onOpenCart: openCart,
              cart: cart,
              cartRevision: cartRevision,
            ),
      ),
    );
  }

  Future<void> chooseLocation() async {
    final address = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (context) => AddressScreen(
              authService: _authService,
              customerName: currentCustomerName,
              mobileNumber: currentCustomerMobile,
            ),
      ),
    );

    if (address != null && mounted) {
      setState(() => confirmedAddress = address);
    }
  }

  Future<void> chooseDeliveryAddress() async {
    final selection = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder:
          (sheetContext) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choose delivery address',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_isLoadingAddresses)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (savedAddresses.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('No saved addresses yet.'),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final address in savedAddresses)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                _isAddressServiceable(address)
                                    ? Icons.location_on_outlined
                                    : Icons.location_off_outlined,
                                color:
                                    _isAddressServiceable(address)
                                        ? Colors.green
                                        : Colors.red,
                              ),
                              title: Text(
                                '${address['house'] ?? ''}, ${address['area'] ?? ''}',
                              ),
                              subtitle: Text(
                                'Pincode ${address['pincode'] ?? ''}'
                                '${_isAddressServiceable(address) ? '' : ' · Not serviceable'}',
                              ),
                              onTap: () {
                                if (!_isAddressServiceable(address)) {
                                  ScaffoldMessenger.of(
                                    sheetContext,
                                  ).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'This address is outside our supported delivery areas.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.pop(sheetContext, address);
                              },
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed:
                        () => Navigator.pop(sheetContext, <String, dynamic>{
                          '_addNewAddress': true,
                        }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add New Address'),
                  ),
                ],
              ),
            ),
          ),
    );

    if (!mounted || selection == null) return;
    if (selection['_addNewAddress'] == true) {
      final address = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder:
              (context) => AddressScreen(
                authService: _authService,
                customerName: currentCustomerName,
                mobileNumber: currentCustomerMobile,
                returnAddress: true,
              ),
        ),
      );
      if (address != null && mounted) {
        setState(() => confirmedAddress = address);
      }
      return;
    }

    if (!_isAddressServiceable(selection)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This address is outside our supported delivery areas.',
          ),
        ),
      );
      return;
    }
    final addressId = selection['id']?.toString();
    if (addressId == null || addressId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This saved address needs to be updated.'),
        ),
      );
      return;
    }
    try {
      await _authService.setDefaultCustomerAddress(addressId);
      if (!mounted) return;
      setState(() {
        confirmedAddress = selection;
        _defaultAddressIsInvalid = false;
      });
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locationStatus =
        widget.serviceabilityMessage ??
        (widget.currentLocationServiceable == true
            ? "You're in our serviceable area."
            : widget.currentLocationServiceable == false
            ? "We're currently outside our delivery area."
            : "We couldn't determine your current location.");

    return Scaffold(
      appBar: AppBar(
        title: const Text('Karjat Cart'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: openCart,
            icon: Badge(
              isLabelVisible: cartItemCount > 0,
              label: Text('$cartItemCount'),
              child: const Icon(Icons.shopping_cart),
            ),
          ),

          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const OrdersScreen()),
              );
            },
            icon: const Icon(Icons.receipt_long),
          ),

          IconButton(
            tooltip: 'Customer Profile',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => CustomerProfileScreen(
                        customerName: currentCustomerName,
                        currentAddress: deliveryAddress,
                      ),
                ),
              );
            },
            icon: const Icon(Icons.person),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color:
                    widget.currentLocationServiceable == true
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    locationStatus,
                    style: TextStyle(
                      color:
                          widget.currentLocationServiceable == true
                              ? Colors.green.shade900
                              : Colors.brown.shade800,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.currentLocationArea?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 3),
                    Text('Current location: ${widget.currentLocationArea}'),
                  ],
                  if (_defaultAddressIsInvalid) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Your saved default address is outside our supported delivery areas.',
                    ),
                  ],
                  if (_addressLoadError != null) ...[
                    const SizedBox(height: 6),
                    Text(_addressLoadError!),
                  ],
                  TextButton.icon(
                    onPressed: chooseDeliveryAddress,
                    icon: const Icon(Icons.location_searching),
                    label: Text(
                      deliveryAddress == null
                          ? 'Select Address Manually'
                          : 'Change Delivery Address',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              deliveryAddress == null
                  ? 'No delivery address selected'
                  : 'Delivering to: ${deliveryAddress!['house'] ?? ''}, '
                      '${deliveryAddress!['area'] ?? ''} '
                      '${deliveryAddress!['pincode'] ?? ''}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: chooseDeliveryAddress,
                icon: const Icon(Icons.home_work_outlined),
                label: const Text('Delivery Address'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search groceries...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Fresh groceries,',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'delivered to your doorstep!',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Shop locally with KarjatCart',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            const Text(
              'Shop by Category',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1.05,
              children: [
                ...categoryDefinitions.map(
                  (category) => CategoryCard(
                    title: category.name,
                    icon: category.icon,
                    onTap: () => openCategory(category.name),
                  ),
                ),
                CategoryCard(
                  title: 'More',
                  icon: Icons.more_horiz,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder:
                            (context) => AllCategoriesScreen(
                              onCategorySelected: openCategory,
                              onOpenCart: openCart,
                              cart: cart,
                              cartRevision: cartRevision,
                            ),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Coming to Karjat this weekend?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Order your groceries before you arrive.',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
            if (searchController.text.trim().isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                'Search Results',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              if (searchResults.isEmpty)
                const Text('No matching products found.')
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: searchResults.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.8,
                  ),
                  itemBuilder: (context, index) {
                    final product = searchResults[index];
                    return _HomeSearchProductCard(
                      product: product,
                      onTap:
                          () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (context) => ProductDetailsScreen(
                                    product: product,
                                    onAddToCart: () => addToCart(product),
                                  ),
                            ),
                          ),
                      onAdd: () => addToCart(product),
                    );
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HomeSearchProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  final VoidCallback onAdd;

  const _HomeSearchProductCard({
    required this.product,
    required this.onTap,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Icon(product.icon, size: 52, color: Colors.green),
                ),
              ),
              Text(
                product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                product.brand,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
              const SizedBox(height: 3),
              Text(
                '₹${product.price.toStringAsFixed(0)}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                height: 30,
                child: ElevatedButton(
                  onPressed: onAdd,
                  style: ElevatedButton.styleFrom(padding: EdgeInsets.zero),
                  child: const Text('ADD', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CategoryCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const CategoryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.green, size: 28),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class AllCategoriesScreen extends StatefulWidget {
  final ValueChanged<String> onCategorySelected;
  final VoidCallback onOpenCart;
  final Map<String, int> cart;
  final ValueNotifier<int> cartRevision;

  const AllCategoriesScreen({
    super.key,
    required this.onCategorySelected,
    required this.onOpenCart,
    required this.cart,
    required this.cartRevision,
  });

  @override
  State<AllCategoriesScreen> createState() => _AllCategoriesScreenState();
}

class _AllCategoriesScreenState extends State<AllCategoriesScreen> {
  int get cartItemCount =>
      widget.cart.values.fold(0, (sum, quantity) => sum + quantity);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('All Categories'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: widget.onOpenCart,
            icon: ValueListenableBuilder<int>(
              valueListenable: widget.cartRevision,
              builder:
                  (context, revision, child) => Badge(
                    isLabelVisible: cartItemCount > 0,
                    label: Text('$cartItemCount'),
                    child: const Icon(Icons.shopping_cart),
                  ),
            ),
          ),
        ],
      ),
      body: GridView.count(
        padding: const EdgeInsets.all(16),
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1.05,
        children: [
          ...categoryDefinitions.map(
            (category) => CategoryCard(
              title: category.name,
              icon: category.icon,
              onTap: () => widget.onCategorySelected(category.name),
            ),
          ),
        ],
      ),
    );
  }
}

class ProductListScreen extends StatefulWidget {
  final String categoryName;
  final Function(Product) onAddToCart;
  final VoidCallback? onOpenCart;
  final Map<String, int> cart;
  final ValueNotifier<int> cartRevision;

  const ProductListScreen({
    super.key,
    required this.categoryName,
    required this.onAddToCart,
    required this.cart,
    required this.cartRevision,
    this.onOpenCart,
  });

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  int get cartItemCount =>
      widget.cart.values.fold(0, (sum, quantity) => sum + quantity);

  List<Product> get products =>
      allProducts
          .where((product) => product.category == widget.categoryName)
          .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.categoryName),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        actions: [
          if (widget.onOpenCart != null)
            IconButton(
              onPressed: widget.onOpenCart,
              icon: ValueListenableBuilder<int>(
                valueListenable: widget.cartRevision,
                builder:
                    (context, revision, child) => Badge(
                      isLabelVisible: cartItemCount > 0,
                      label: Text('$cartItemCount'),
                      child: const Icon(Icons.shopping_cart),
                    ),
              ),
            ),
        ],
      ),
      body:
          products.isEmpty
              ? Center(
                child: Text(
                  'No products available in ${widget.categoryName} yet.',
                ),
              )
              : GridView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: products.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemBuilder: (context, index) {
                  final product = products[index];

                  return Card(
                    elevation: 3,
                    child: InkWell(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => ProductDetailsScreen(
                                  product: product,
                                  onAddToCart: () {
                                    widget.onAddToCart(product);
                                    setState(() {});
                                  },
                                ),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(product.icon, size: 48, color: Colors.green),
                            const SizedBox(height: 6),
                            Text(
                              product.name,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              product.brand,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '₹${product.price.toStringAsFixed(0)}',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ElevatedButton(
                              onPressed: () {
                                widget.onAddToCart(product);
                                setState(() {});
                              },
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 30),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                              ),
                              child: const Text(
                                'ADD',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
    );
  }
}

class CartScreen extends StatefulWidget {
  final List<Product> products;
  final Map<String, int> cart;
  final Map<String, dynamic>? initialAddress;
  final VoidCallback onCartChanged;

  const CartScreen({
    super.key,
    required this.products,
    required this.cart,
    this.initialAddress,
    required this.onCartChanged,
  });

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final FirebasePhoneAuthService _authService = FirebasePhoneAuthService();
  Map<String, dynamic>? savedAddress;
  bool _isResolvingOrderMobile = false;

  /// Guards against duplicate order creation.
  ///
  /// Unlike [_isResolvingOrderMobile] (which only tracks phone-number
  /// resolution), this flag is set for the whole flow - validation, customer
  /// mobile resolution, order construction, the Firestore write and the
  /// navigation to the confirmation screen - and is only reset when the
  /// operation fails while the user is still on the cart screen.
  bool _isPlacingOrder = false;

  String selectedPaymentMethod = 'Cash on Delivery';
  String selectedScheduleType = 'now';
  DateTime? selectedDeliveryDate;
  DeliverySlot? selectedDeliverySlot;

  @override
  void initState() {
    super.initState();
    savedAddress = widget.initialAddress;
  }

  double get subtotal {
    double total = 0;

    for (final product in widget.products) {
      final quantity = widget.cart[product.name] ?? 0;
      total += product.price * quantity;
    }

    return total;
  }

  double get deliveryCharge {
    if (subtotal == 0) {
      return 0;
    }

    if (subtotal >= 499) {
      return 0;
    }

    return 30;
  }

  double get grandTotal {
    return subtotal + deliveryCharge;
  }

  /// Returns true when a new order flow may start.
  ///
  /// This check runs synchronously before any `await`, so two very fast taps
  /// can never both enter the flow: the first tap flips [_isPlacingOrder] to
  /// true synchronously, and the second tap then sees it and bails out.
  bool _beginPlacingOrder() {
    if (_isPlacingOrder) return false;
    setState(() => _isPlacingOrder = true);
    return true;
  }

  void changeQuantity(Product product, int change) {
    setState(() {
      final currentQuantity = widget.cart[product.name] ?? 0;
      final newQuantity = currentQuantity + change;

      if (newQuantity <= 0) {
        widget.cart.remove(product.name);
      } else {
        widget.cart[product.name] = newQuantity;
      }
    });

    widget.onCartChanged();
  }

  bool isSlotAvailable(DeliverySlot slot, DateTime date) {
    if (slot.isFull) return false;
    if (date.year != DateTime.now().year ||
        date.month != DateTime.now().month ||
        date.day != DateTime.now().day) {
      return true;
    }

    final startHour = int.parse(slot.startTime.split(':').first);
    final isPm = slot.startTime.endsWith('PM');
    final hour24 = (startHour % 12) + (isPm ? 12 : 0);
    final start = DateTime(date.year, date.month, date.day, hour24);
    return start.isAfter(DateTime.now());
  }

  Future<void> selectDeliveryDate() async {
    final today = DateTime.now();
    final lastDate = today.add(const Duration(days: scheduleWindowDays - 1));
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: DateTime(lastDate.year, lastDate.month, lastDate.day),
      initialDate: selectedDeliveryDate ?? today,
    );
    if (date == null) return;
    setState(() {
      selectedDeliveryDate = date;
      selectedDeliverySlot = null;
    });
  }

  bool validateSchedule() {
    if (selectedScheduleType != 'scheduled') return true;
    if (selectedDeliveryDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a delivery date.')),
      );
      return false;
    }
    if (selectedDeliverySlot == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a delivery time slot.')),
      );
      return false;
    }
    final currentSlot = slotsForDate(
      selectedDeliveryDate!,
    ).firstWhere((slot) => slot.id == selectedDeliverySlot!.id);
    if (!isSlotAvailable(currentSlot, selectedDeliveryDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This delivery slot is no longer available.'),
        ),
      );
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cartProducts =
        widget.products
            .where((product) => (widget.cart[product.name] ?? 0) > 0)
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Cart'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body:
          cartProducts.isEmpty
              ? const Center(
                child: Text(
                  'Your cart is empty',
                  style: TextStyle(fontSize: 20),
                ),
              )
              : SingleChildScrollView(
                child: Column(
                  children: [
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: cartProducts.length,
                      itemBuilder: (context, index) {
                        final product = cartProducts[index];
                        final quantity = widget.cart[product.name] ?? 0;

                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: ListTile(
                            leading: Icon(
                              product.icon,
                              color: Colors.green,
                              size: 35,
                            ),
                            title: Text(product.name),
                            subtitle: Text(
                              '₹${product.price.toStringAsFixed(0)} each\n'
                              'Total: ₹${(product.price * quantity).toStringAsFixed(0)}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () => changeQuantity(product, -1),
                                  icon: const Icon(Icons.remove),
                                ),
                                Text(
                                  '$quantity',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => changeQuantity(product, 1),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    if (savedAddress != null) ...[
                      const SizedBox(height: 12),

                      // DELIVERY ADDRESS
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Delivery Address',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),

                            Text('Name: ${savedAddress!['name']}'),
                            Text('Mobile: ${savedAddress!['mobile']}'),
                            Text('House: ${savedAddress!['house']}'),
                            Text('Area: ${savedAddress!['area']}'),
                            Text('Pincode: ${savedAddress!['pincode']}'),
                            Text('Landmark: ${savedAddress!['landmark']}'),

                            const SizedBox(height: 8),

                            TextButton(
                              onPressed: () async {
                                final result =
                                    await Navigator.push<Map<String, dynamic>>(
                                      context,
                                      MaterialPageRoute(
                                        builder:
                                            (context) => AddressScreen(
                                              initialAddress: savedAddress,
                                              mobileNumber:
                                                  savedAddress!['mobile']
                                                      ?.toString(),
                                              returnAddress: true,
                                            ),
                                      ),
                                    );

                                if (result != null) {
                                  setState(() => savedAddress = result);
                                }
                              },
                              child: const Text('CHANGE ADDRESS'),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 15),

                      // ORDER SUMMARY
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Order Summary',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 12),

                            ...cartProducts.map((product) {
                              final quantity = widget.cart[product.name] ?? 0;

                              final itemTotal = product.price * quantity;

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${product.name} × $quantity',
                                      ),
                                    ),
                                    Text('₹${itemTotal.toStringAsFixed(0)}'),
                                  ],
                                ),
                              );
                            }),

                            const Divider(height: 25),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Subtotal'),
                                Text('₹${subtotal.toStringAsFixed(0)}'),
                              ],
                            ),

                            const SizedBox(height: 8),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Delivery Charge'),
                                Text(
                                  deliveryCharge == 0
                                      ? 'FREE'
                                      : '₹${deliveryCharge.toStringAsFixed(0)}',
                                ),
                              ],
                            ),

                            const Divider(height: 25),

                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Grand Total',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '₹${grandTotal.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 15),

                      // DELIVERY PREFERENCE
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Delivery Preference',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Order Now'),
                              value: 'now',
                              groupValue: selectedScheduleType,
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() {
                                  selectedScheduleType = value;
                                  selectedDeliveryDate = null;
                                  selectedDeliverySlot = null;
                                });
                              },
                            ),
                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Schedule Order'),
                              value: 'scheduled',
                              groupValue: selectedScheduleType,
                              onChanged: (value) {
                                if (value == null) return;
                                setState(() => selectedScheduleType = value);
                              },
                            ),
                            if (selectedScheduleType == 'scheduled') ...[
                              OutlinedButton.icon(
                                onPressed: selectDeliveryDate,
                                icon: const Icon(Icons.calendar_today),
                                label: Text(
                                  selectedDeliveryDate == null
                                      ? 'Select Delivery Date'
                                      : formatDeliveryDate(
                                        selectedDeliveryDate!,
                                      ),
                                ),
                              ),
                              if (selectedDeliveryDate != null) ...[
                                const SizedBox(height: 12),
                                const Text(
                                  'Available Time Slots',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                ...slotsForDate(selectedDeliveryDate!).map((
                                  slot,
                                ) {
                                  final available = isSlotAvailable(
                                    slot,
                                    selectedDeliveryDate!,
                                  );
                                  final selected =
                                      selectedDeliverySlot?.id == slot.id;
                                  return Card(
                                    color:
                                        selected ? Colors.green.shade50 : null,
                                    child: RadioListTile<String>(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                      value: slot.id,
                                      groupValue: selectedDeliverySlot?.id,
                                      onChanged:
                                          available
                                              ? (_) => setState(
                                                () =>
                                                    selectedDeliverySlot = slot,
                                              )
                                              : null,
                                      title: Text(
                                        '${slot.startTime} - ${slot.endTime}',
                                      ),
                                      subtitle: Text(
                                        slot.isFull
                                            ? 'FULL'
                                            : '${slot.remainingCapacity} / ${slot.capacity} slots available',
                                        style: TextStyle(
                                          color:
                                              slot.isFull
                                                  ? Colors.red
                                                  : Colors.grey.shade700,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 15),

                      // PAYMENT METHOD
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Payment Method',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 8),

                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Cash on Delivery'),
                              value: 'Cash on Delivery',
                              groupValue: selectedPaymentMethod,
                              onChanged: (value) {
                                if (value == null) return;

                                setState(() {
                                  selectedPaymentMethod = value;
                                });
                              },
                            ),

                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'Online Payment',
                                style: TextStyle(color: Colors.grey),
                              ),
                              subtitle: const Text('Coming soon'),
                              value: 'Online Payment',
                              groupValue: selectedPaymentMethod,
                              onChanged: null,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 15),

                      // PLACE ORDER
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _isPlacingOrder || _isResolvingOrderMobile
                                  ? null
                                  : () async {
                                    // Synchronous re-entrancy guard: runs
                                    // before any await, so a second tap that
                                    // lands before the first finishes is
                                    // rejected here.
                                    if (!_beginPlacingOrder()) return;

                                    // Only reachable when the flow is aborted
                                    // while the user stays on the cart screen.
                                    // Deliberately NOT called after the
                                    // Firestore write succeeds.
                                    void abortOrder() {
                                      if (mounted) {
                                        setState(
                                          () => _isPlacingOrder = false,
                                        );
                                      }
                                    }

                                    if (!validateSchedule()) {
                                      abortOrder();
                                      return;
                                    }
                                    final firebaseUser =
                                        FirebaseAuth.instance.currentUser;
                                    if (firebaseUser == null) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Please sign in before placing an order.',
                                          ),
                                        ),
                                      );
                                      abortOrder();
                                      return;
                                    }
                                    setState(
                                      () => _isResolvingOrderMobile = true,
                                    );
                                    final scaffoldMessenger =
                                        ScaffoldMessenger.of(context);
                                    final navigator = Navigator.of(context);

                                    late final Map<String, dynamic>
                                    orderAddress;
                                    try {
                                      orderAddress =
                                          await _addressWithVerifiedCustomerMobile(
                                            savedAddress!,
                                            _authService,
                                          );
                                    } on FirebaseCustomerProfileException catch (
                                      exception
                                    ) {
                                      if (!mounted) return;
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Text(exception.message),
                                        ),
                                      );
                                      abortOrder();
                                      return;
                                    } finally {
                                      if (mounted) {
                                        setState(
                                          () => _isResolvingOrderMobile = false,
                                        );
                                      }
                                    }
                                    if (!mounted) return;

                                    var customerName =
                                        currentCustomerName.trim();
                                    if (customerName.isEmpty) {
                                      try {
                                        final customerProfile =
                                            await _authService
                                                .getCurrentCustomerProfile();
                                        customerName =
                                            customerProfile?['fullName']
                                                ?.toString()
                                                .trim() ??
                                            '';
                                      } on FirebaseCustomerProfileException {
                                        customerName = '';
                                      }
                                      if (customerName.isEmpty) {
                                        customerName =
                                            firebaseUser.displayName?.trim() ??
                                            '';
                                      }
                                    }
                                    late final String customerMobile;
                                    try {
                                      final verifiedMobile =
                                          await _authService
                                              .getCurrentVerifiedMobileNumber();
                                      customerMobile =
                                          verifiedMobile?.trim().isNotEmpty ==
                                                  true
                                              ? verifiedMobile!.trim()
                                              : orderAddress['mobile']
                                                      ?.toString()
                                                      .trim() ??
                                                  '';
                                    } on FirebaseCustomerProfileException catch (
                                      exception
                                    ) {
                                      if (!mounted) return;
                                      scaffoldMessenger.showSnackBar(
                                        SnackBar(
                                          content: Text(exception.message),
                                        ),
                                      );
                                      abortOrder();
                                      return;
                                    }
                                    if (!mounted) return;
                                    if ((savedAddress!['mobile']
                                                ?.toString()
                                                .trim() ??
                                            '')
                                        .isEmpty) {
                                      setState(
                                        () => savedAddress = orderAddress,
                                      );
                                    }

                                    final orderDateTime = DateTime.now();

                                    final orderId =
                                        'KE${orderDateTime.millisecondsSinceEpoch}';

                                    if (selectedScheduleType == 'scheduled') {
                                      final slot = slotsForDate(
                                        selectedDeliveryDate!,
                                      ).firstWhere(
                                        (candidate) =>
                                            candidate.id ==
                                            selectedDeliverySlot!.id,
                                      );
                                      if (slot.isFull) {
                                        scaffoldMessenger.showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'This delivery slot is no longer available. Please select another slot.',
                                            ),
                                          ),
                                                                                    );
                                                                                  abortOrder();
                                                                                  return;
                                                                                }
                                                                                slot.bookedOrders += 1;
                                    }

                                    final order = <String, dynamic>{
                                      'orderId': orderId,
                                      'date': orderDateTime,
                                      'deliveryCharge': deliveryCharge,
                                      'total': grandTotal,
                                      'address': orderAddress,
                                      'paymentMethod': selectedPaymentMethod,
                                      'status': orderStatuses.first,
                                      'customerUid': firebaseUser.uid,
                                      'customerName': customerName,
                                      'customerMobile': customerMobile,
                                      'scheduleType': selectedScheduleType,
                                      'scheduledDate':
                                          selectedDeliveryDate == null
                                              ? null
                                              : deliveryDateKey(
                                                selectedDeliveryDate!,
                                              ),
                                      'scheduledStartTime':
                                          selectedDeliverySlot?.startTime,
                                      'scheduledEndTime':
                                          selectedDeliverySlot?.endTime,
                                      'slotId': selectedDeliverySlot?.id,
                                      'products':
                                          widget.products
                                              .where(
                                                (product) =>
                                                    (widget.cart[product
                                                            .name] ??
                                                        0) >
                                                    0,
                                              )
                                              .map(
                                                (product) => {
                                                  'name': product.name,
                                                  'quantity':
                                                      widget.cart[product
                                                          .name] ??
                                                      0,
                                                  'price': product.price,
                                                },
                                              )
                                              .toList(),
                                      'createdAt': FieldValue.serverTimestamp(),
                                    };

                                    try {
                                      await FirebaseFirestore.instance
                                          .collection('orders')
                                          .doc(orderId)
                                          .set(order);
                                    } on FirebaseException {
                                      if (!mounted) return;
                                      scaffoldMessenger.showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'We could not save your order. Please check your connection and try again.',
                                          ),
                                        ),
                                      );
                                      abortOrder();
                                      return;
                                    } catch (_) {
                                      if (!mounted) return;
                                      scaffoldMessenger.showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'We could not save your order. Please try again.',
                                          ),
                                        ),
                                      );
                                      abortOrder();
                                      return;
                                    }
                                    if (!mounted) return;

                                    // ---------------------------------------------------------------
                                    // Firestore has now CONFIRMED the order. Everything below
                                    // is success-only: the cart may be cleared, and the
                                    // button stays disabled because [_isPlacingOrder] is
                                    // intentionally never reset on the success path.
                                    // ---------------------------------------------------------------

                                    // Capture the totals and line items BEFORE
                                    // clearing, because OrderConfirmationScreen
                                    // reads them after the cart is emptied.
                                    final placedCart = Map<String, int>.from(
                                      widget.cart,
                                    );
                                    final placedTotal = grandTotal;
                                    final placedDeliveryCharge = deliveryCharge;

                                    // Clear the shared cart in place (never reassign), so the
                                    // HomeScreen-held Map instance stays intact.
                                    widget.cart.clear();
                                    widget.onCartChanged();

                                    savedOrders.add({
                                      ...order,
                                      'createdAt': orderDateTime,
                                    });

                                    navigator.push(
                                      MaterialPageRoute(
                                        builder:
                                            (
                                              context,
                                            ) => OrderConfirmationScreen(
                                              products: widget.products,
                                              cart: placedCart,
                                              address: orderAddress,
                                              total: placedTotal,
                                              orderId: orderId,
                                              orderDateTime: orderDateTime,
                                              deliveryCharge:
                                                  placedDeliveryCharge,
                                              paymentMethod:
                                                  selectedPaymentMethod,
                                              status: orderStatuses.first,
                                              scheduleType:
                                                  selectedScheduleType,
                                              scheduledDate:
                                                  selectedDeliveryDate,
                                              scheduledStartTime:
                                                  selectedDeliverySlot
                                                      ?.startTime,
                                              scheduledEndTime:
                                                  selectedDeliverySlot?.endTime,
                                            ),
                                      ),
                                    );
                                  },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text(
                            'PLACE ORDER',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
    );
  }
}

class OrderConfirmationScreen extends StatelessWidget {
  final List<Product> products;
  final Map<String, int> cart;
  final Map<String, dynamic> address;
  final double total;
  final String orderId;
  final DateTime orderDateTime;
  final double deliveryCharge;
  final String paymentMethod;
  final String status;
  final String scheduleType;
  final DateTime? scheduledDate;
  final String? scheduledStartTime;
  final String? scheduledEndTime;

  const OrderConfirmationScreen({
    super.key,
    required this.products,
    required this.cart,
    required this.address,
    required this.total,
    required this.orderId,
    required this.orderDateTime,
    required this.deliveryCharge,
    this.paymentMethod = 'Cash on Delivery',
    this.status = 'Preparing Order',
    this.scheduleType = 'now',
    this.scheduledDate,
    this.scheduledStartTime,
    this.scheduledEndTime,
  });

  @override
  Widget build(BuildContext context) {
    final orderedProducts =
        products.where((product) => (cart[product.name] ?? 0) > 0).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Confirmation'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 90),
            const SizedBox(height: 15),
            const Center(
              child: Text(
                'Order Placed Successfully!',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text(
                'Thank you for shopping with us.',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 25),
            Text(
              'Order ID: $orderId',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text('Order Date & Time: ${_formatOrderDateTime(orderDateTime)}'),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Payment Method'),
                Text(
                  paymentMethod,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (scheduleType == 'scheduled' && scheduledDate != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Scheduled Delivery',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(formatDeliveryDate(scheduledDate!)),
              Text('${scheduledStartTime ?? ''} - ${scheduledEndTime ?? ''}'),
            ],
            const SizedBox(height: 20),
            const Text(
              'Order Details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            ...orderedProducts.map((product) {
              final quantity = cart[product.name] ?? 0;
              final itemTotal = product.price * quantity;

              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(product.name),
                subtitle: Text('Quantity: $quantity'),
                trailing: Text('₹${itemTotal.toStringAsFixed(0)}'),
              );
            }),

            const Divider(height: 30),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Delivery charge'),
                Text(
                  deliveryCharge == 0
                      ? 'FREE'
                      : '₹${deliveryCharge.toStringAsFixed(0)}',
                ),
              ],
            ),
            const SizedBox(height: 12),

            const Text(
              'Delivery Address',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Text('Name: ${address['name']}'),
            Text('Mobile: ${address['mobile']}'),
            Text('House: ${address['house']}'),
            Text('Area: ${address['area']}'),
            Text('Pincode: ${address['pincode']}'),
            Text('Landmark: ${address['landmark']}'),

            const SizedBox(height: 25),

            Text(
              'Total Amount: ₹${total.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 25),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder:
                          (context) => TrackOrderScreen(
                            orderId: orderId,
                            address: address,
                            status: status,
                            scheduleType: scheduleType,
                            scheduledDate: scheduledDate,
                            scheduledStartTime: scheduledStartTime,
                            scheduledEndTime: scheduledEndTime,
                          ),
                    ),
                  );
                },
                icon: const Icon(Icons.location_on),
                label: const Text('TRACK ORDER'),
              ),
            ),
            const SizedBox(height: 12),

            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Order Status: $status',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 25),

            ElevatedButton(
              onPressed: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => HomeScreen(
                          deliveryAddress: address,
                          mobileNumber: address['mobile']?.toString(),
                        ),
                  ),
                  (route) => false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              child: const Text(
                'CONTINUE SHOPPING',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TrackOrderScreen extends StatelessWidget {
  final String orderId;
  final Map<String, dynamic> address;
  final String status;
  final String scheduleType;
  final DateTime? scheduledDate;
  final String? scheduledStartTime;
  final String? scheduledEndTime;

  const TrackOrderScreen({
    super.key,
    required this.orderId,
    required this.address,
    this.status = 'Preparing Order',
    this.scheduleType = 'now',
    this.scheduledDate,
    this.scheduledStartTime,
    this.scheduledEndTime,
  });

  @override
  Widget build(BuildContext context) {
    final latitude = (address['latitude'] as num?)?.toDouble();
    final longitude = (address['longitude'] as num?)?.toDouble();
    final location = [
      address['area'],
      address['pincode'],
    ].where((value) => value != null && value.toString().isNotEmpty).join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Track Order'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Order ID: $orderId',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Container(
            height: 260,
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(double.infinity, 260),
                  painter: _MapGridPainter(),
                ),
                const Icon(Icons.location_pin, color: Colors.red, size: 58),
                const Positioned(
                  left: 18,
                  bottom: 16,
                  child: Text(
                    'Delivery location',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (scheduleType == 'scheduled' && scheduledDate != null) ...[
            const Text(
              'Scheduled Delivery',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            Text(formatDeliveryDate(scheduledDate!)),
            Text('${scheduledStartTime ?? ''} - ${scheduledEndTime ?? ''}'),
            const SizedBox(height: 18),
          ],
          const Text(
            'Order Status',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ..._buildStatusTimeline(),
          const Divider(),
          const Text(
            'Delivery Location',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(location.isEmpty ? 'Location saved in your address' : location),
          if (latitude != null && longitude != null) ...[
            const SizedBox(height: 4),
            Text(
              'Coordinates: ${latitude.toStringAsFixed(6)}, '
              '${longitude.toStringAsFixed(6)}',
            ),
          ],
          Text('Landmark: ${address['landmark'] ?? ''}'),
        ],
      ),
    );
  }

  List<Widget> _buildStatusTimeline() {
    final currentIndex = orderStatusIndex(status);

    return [
      for (var index = 0; index < orderStatuses.length; index++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            index <= currentIndex
                ? Icons.check_circle
                : Icons.radio_button_unchecked,
            color: index <= currentIndex ? Colors.green : Colors.grey,
          ),
          title: Text(
            orderStatuses[index],
            style: TextStyle(
              fontWeight:
                  index == currentIndex ? FontWeight.bold : FontWeight.normal,
              color: index <= currentIndex ? Colors.green.shade800 : null,
            ),
          ),
          subtitle:
              index == currentIndex ? const Text('Current order status') : null,
        ),
    ];
  }
}

class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.green.shade100
          ..strokeWidth = 2;
    for (var x = 0.0; x <= size.width; x += 42) {
      canvas.drawLine(Offset(x, 0), Offset(x + 70, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += 42) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 45), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late final String? _customerUid = FirebaseAuth.instance.currentUser?.uid;
  late Future<List<Map<String, dynamic>>> _ordersFuture = _loadOrders(
    _customerUid,
  );

  Future<List<Map<String, dynamic>>> _loadOrders(String? customerUid) async {
    if (customerUid == null) return <Map<String, dynamic>>[];

    final snapshot =
        await FirebaseFirestore.instance
            .collection('orders')
            .where('customerUid', isEqualTo: customerUid)
            .get();
    if (FirebaseAuth.instance.currentUser?.uid != customerUid) {
      return <Map<String, dynamic>>[];
    }

    final orders = snapshot.docs.map(_normalizeOrder).toList();
    orders.sort(
      (first, second) =>
          (second['date'] as DateTime).compareTo(first['date'] as DateTime),
    );
    return orders;
  }

  DateTime? _dateTimeFrom(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Map<String, dynamic> _normalizeOrder(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final rawProducts = data['products'];
    final products =
        rawProducts is List
            ? rawProducts.whereType<Map>().map((rawProduct) {
              final product = Map<String, dynamic>.from(rawProduct);
              final quantity = product['quantity'];
              final price = product['price'];
              return <String, dynamic>{
                'name': product['name']?.toString() ?? 'Item',
                'quantity': quantity is num ? quantity.toInt() : 0,
                'price': price is num ? price.toDouble() : 0.0,
              };
            }).toList()
            : <Map<String, dynamic>>[];
    final rawAddress = data['address'];
    final address =
        rawAddress is Map
            ? Map<String, dynamic>.from(rawAddress)
            : <String, dynamic>{};
    final rawScheduledDate = data['scheduledDate']?.toString();
    String? scheduledDate;
    try {
      final parsedDate = parseDeliveryDate(rawScheduledDate);
      scheduledDate = parsedDate == null ? null : deliveryDateKey(parsedDate);
    } catch (_) {
      scheduledDate = null;
    }

    return {
      ...data,
      'orderId':
          data['orderId']?.toString().trim().isNotEmpty == true
              ? data['orderId'].toString()
              : document.id,
      'date':
          _dateTimeFrom(data['date']) ??
          _dateTimeFrom(data['createdAt']) ??
          DateTime.now(),
      'createdAt': _dateTimeFrom(data['createdAt']),
      'deliveryCharge':
          data['deliveryCharge'] is num
              ? (data['deliveryCharge'] as num).toDouble()
              : 0.0,
      'total': data['total'] is num ? (data['total'] as num).toDouble() : 0.0,
      'address': address,
      'paymentMethod': data['paymentMethod']?.toString() ?? 'Cash on Delivery',
      'status': data['status']?.toString() ?? orderStatuses.first,
      'scheduleType': data['scheduleType']?.toString() ?? 'now',
      'scheduledDate': scheduledDate,
      'scheduledStartTime': data['scheduledStartTime']?.toString(),
      'scheduledEndTime': data['scheduledEndTime']?.toString(),
      'slotId': data['slotId']?.toString(),
      'products': products,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Orders'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body:
          _customerUid == null
              ? const Center(child: Text('Sign in to view your orders.'))
              : FutureBuilder<List<Map<String, dynamic>>>(
                future: _ordersFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Unable to load your orders.'),
                          TextButton.icon(
                            onPressed: () {
                              setState(
                                () => _ordersFuture = _loadOrders(_customerUid),
                              );
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('Try again'),
                          ),
                        ],
                      ),
                    );
                  }
                  final orders = snapshot.data ?? <Map<String, dynamic>>[];
                  if (orders.isEmpty) {
                    return const Center(
                      child: Text(
                        'No orders yet',
                        style: TextStyle(fontSize: 20),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: orders.length,
                    itemBuilder: (context, index) {
                      final order = orders[index];
                      final orderDateTime = order['date'] as DateTime;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: const Icon(
                            Icons.receipt_long,
                            color: Colors.green,
                            size: 35,
                          ),

                          title: Text(
                            'Order ID: ${order['orderId']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),

                          subtitle: Text(
                            'Date: ${_formatOrderDateTime(orderDateTime)}\n'
                            'Amount: ₹${(order['total'] as num).toStringAsFixed(0)}\n'
                            'Status: ${order['status'] ?? orderStatuses.first}\n'
                            'Payment: ${order['paymentMethod'] ?? 'Cash on Delivery'}\n'
                            '${order['scheduleType'] == 'scheduled' ? 'Scheduled: ${formatDeliveryDate(parseDeliveryDate(order['scheduledDate']) ?? orderDateTime)}\n${order['scheduledStartTime']} - ${order['scheduledEndTime']}\n' : ''}'
                            'Tap for Order Details',
                          ),

                          isThreeLine: true,

                          trailing: const Icon(Icons.arrow_forward_ios),

                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder:
                                    (context) => OrderConfirmationScreen(
                                      products:
                                          (order['products'] as List)
                                              .map(
                                                (item) => Product(
                                                  name: item['name'],
                                                  brand: '',
                                                  price: item['price'],
                                                  icon: Icons.shopping_basket,
                                                ),
                                              )
                                              .toList(),

                                      cart: {
                                        for (final item
                                            in (order['products'] as List))
                                          item['name']: item['quantity'] as int,
                                      },

                                      address: order['address'],
                                      total: order['total'],
                                      orderId: order['orderId'],
                                      orderDateTime: orderDateTime,
                                      deliveryCharge:
                                          (order['deliveryCharge'] as num?)
                                              ?.toDouble() ??
                                          0,
                                      paymentMethod:
                                          order['paymentMethod']?.toString() ??
                                          'Cash on Delivery',
                                      status:
                                          order['status']?.toString() ??
                                          orderStatuses.first,
                                      scheduleType:
                                          order['scheduleType']?.toString() ??
                                          'now',
                                      scheduledDate: parseDeliveryDate(
                                        order['scheduledDate']?.toString(),
                                      ),
                                      scheduledStartTime:
                                          order['scheduledStartTime']
                                              ?.toString(),
                                      scheduledEndTime:
                                          order['scheduledEndTime']?.toString(),
                                    ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  );
                },
              ),
    );
  }
}

class CustomerProfileScreen extends StatefulWidget {
  final String customerName;
  final Map<String, dynamic>? currentAddress;

  const CustomerProfileScreen({
    super.key,
    required this.customerName,
    this.currentAddress,
  });

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  late String customerName;
  late final FirebasePhoneAuthService _authService;

  @override
  void initState() {
    super.initState();
    _authService = FirebasePhoneAuthService();
    customerName = widget.customerName;
  }

  Future<void> editProfile() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder:
            (context) => EditProfileScreen(
              customerName: customerName,
              authService: _authService,
            ),
      ),
    );

    if (result == null) return;
    setState(() {
      customerName = result;
      currentCustomerName = result;
    });
  }

  Future<void> logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Logout'),
            content: const Text('Are you sure you want to logout?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Logout'),
              ),
            ],
          ),
    );

    if (shouldLogout != true || !mounted) return;
    await FirebaseAuth.instance.signOut();
    currentCustomerName = '';
    currentCustomerMobile = '';
    savedAddresses.clear();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const SplashNextScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final verifiedMobileNumber =
        _authService.currentUser?.phoneNumber?.trim() ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Profile'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const CircleAvatar(
                    radius: 42,
                    backgroundColor: Color(0xffe6f5eb),
                    child: Icon(Icons.person, size: 48, color: Colors.green),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    customerName.isEmpty ? 'Customer Name' : customerName,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    verifiedMobileNumber.isEmpty
                        ? 'No verified mobile number'
                        : 'Verified mobile number\n$verifiedMobileNumber',
                    textAlign: TextAlign.center,
                  ),
                  TextButton.icon(
                    onPressed: editProfile,
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit Profile'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'My Account',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.receipt_long, color: Colors.green),
                  title: const Text('My Orders'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const OrdersScreen(),
                        ),
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.location_on, color: Colors.green),
                  title: const Text('Saved Addresses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const SavedAddressesScreen(),
                        ),
                      ),
                ),
                ListTile(
                  leading: const Icon(Icons.help_outline, color: Colors.green),
                  title: const Text('Help & Support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap:
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const HelpSupportScreen(),
                        ),
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: logout,
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  final String customerName;
  final FirebasePhoneAuthService authService;

  const EditProfileScreen({
    super.key,
    required this.customerName,
    required this.authService,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController nameController;
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.customerName);
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> saveProfile() async {
    final name = nameController.text.trim();
    if (name.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a name with at least 2 characters.'),
        ),
      );
      return;
    }

    setState(() => isSaving = true);
    try {
      await widget.authService.updateCustomerProfile(fullName: name);
      if (!mounted) return;
      Navigator.pop(context, name);
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to save profile. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final verifiedMobileNumber =
        widget.authService.currentUser?.phoneNumber?.trim() ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Customer Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            verifiedMobileNumber.isEmpty
                ? 'No verified mobile number'
                : 'Verified mobile number\n$verifiedMobileNumber',
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: isSaving ? null : saveProfile,
              child: Text(isSaving ? 'SAVING...' : 'SAVE PROFILE'),
            ),
          ),
        ],
      ),
    );
  }
}

class SavedAddressesScreen extends StatefulWidget {
  final FirebasePhoneAuthService? authService;

  const SavedAddressesScreen({super.key, this.authService});

  @override
  State<SavedAddressesScreen> createState() => _SavedAddressesScreenState();
}

class _SavedAddressesScreenState extends State<SavedAddressesScreen> {
  late final FirebasePhoneAuthService _authService;
  String? _defaultAddressId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? FirebasePhoneAuthService();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    try {
      final addressData = await _authService.loadCustomerAddressData();
      final addresses =
          (addressData['addresses'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map((address) => Map<String, dynamic>.from(address))
              .toList();
      if (!mounted) return;
      setState(() {
        savedAddresses
          ..clear()
          ..addAll(addresses);
        _defaultAddressId = addressData['defaultAddressId']?.toString();
        _isLoading = false;
      });
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    }
  }

  Future<void> addAddress() async {
    final address = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (context) => AddressScreen(
              authService: _authService,
              customerName: currentCustomerName,
              mobileNumber: currentCustomerMobile,
              returnAddress: true,
            ),
      ),
    );
    if (address != null && mounted) {
      setState(() {
        saveCustomerAddress(address);
        _defaultAddressId ??= address['id']?.toString();
      });
    }
  }

  Future<void> editAddress(Map<String, dynamic> address) async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder:
            (context) => AddressScreen(
              initialAddress: address,
              authService: _authService,
              customerName: currentCustomerName,
              mobileNumber: currentCustomerMobile,
              returnAddress: true,
            ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => saveCustomerAddress(updated));
    }
  }

  Future<void> setDefaultAddress(Map<String, dynamic> address) async {
    if (!_isAddressServiceable(address)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This address is outside our supported delivery areas.',
          ),
        ),
      );
      return;
    }
    final addressId = address['id']?.toString();
    if (addressId == null || addressId.isEmpty) return;
    try {
      await _authService.setDefaultCustomerAddress(addressId);
      if (!mounted) return;
      setState(() => _defaultAddressId = addressId);
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    }
  }

  Future<void> deleteAddress(Map<String, dynamic> address) async {
    final addressId = address['id']?.toString();
    if (addressId == null || addressId.isEmpty) return;
    try {
      await _authService.deleteCustomerAddress(addressId);
      if (!mounted) return;
      setState(() {
        savedAddresses.removeWhere(
          (saved) => saved['id']?.toString() == addressId,
        );
        if (_defaultAddressId == addressId) {
          _defaultAddressId = null;
        }
      });
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved Addresses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addAddress,
        icon: const Icon(Icons.add),
        label: const Text('Add New Address'),
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : savedAddresses.isEmpty
              ? const Center(child: Text('No saved addresses yet'))
              : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                itemCount: savedAddresses.length,
                itemBuilder: (context, index) {
                  final address = savedAddresses[index];
                  final isDefault =
                      address['id']?.toString() == _defaultAddressId;
                  final isServiceable = _isAddressServiceable(address);
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  address['name']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                              if (isDefault) const Chip(label: Text('Default')),
                              if (!isServiceable)
                                const Chip(label: Text('Not serviceable')),
                            ],
                          ),
                          Text('Mobile: ${address['mobile'] ?? ''}'),
                          Text('House/Flat: ${address['house'] ?? ''}'),
                          Text('Area: ${address['area'] ?? ''}'),
                          Text('Pincode: ${address['pincode'] ?? ''}'),
                          Text('Landmark: ${address['landmark'] ?? ''}'),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => editAddress(address),
                                icon: const Icon(Icons.edit),
                                label: const Text('Edit'),
                              ),
                              TextButton.icon(
                                onPressed: () => deleteAddress(address),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Delete'),
                              ),
                              TextButton(
                                onPressed: () => setDefaultAddress(address),
                                child: const Text('Set default'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
    );
  }
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  void showSupportMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final faqs = {
      'How to place an order?':
          'Choose a product, add it to your cart, confirm your address, and tap PLACE ORDER.',
      'How to change delivery address?':
          'Open your cart and tap CHANGE ADDRESS below the delivery address.',
      'How to track my order?':
          'Open an order and tap TRACK ORDER to view its delivery progress.',
      'Payment help':
          'Cash on Delivery is currently available. Online payment is coming soon.',
      'Cancellation / refund help':
          'Please contact customer care with your order ID for assistance.',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Customer Care',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          ListTile(
            leading: const Icon(Icons.phone, color: Colors.green),
            title: const Text('Call Customer Care'),
            subtitle: const Text('+91 1800 123 4567'),
            onTap:
                () => showSupportMessage(
                  context,
                  'Customer care: +91 1800 123 4567',
                ),
          ),
          const SizedBox(height: 12),
          const Text(
            'WhatsApp Support',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          ListTile(
            leading: const Icon(Icons.chat, color: Colors.green),
            title: const Text('Chat on WhatsApp'),
            subtitle: const Text('+91 90000 00000'),
            onTap:
                () => showSupportMessage(
                  context,
                  'WhatsApp support: +91 90000 00000',
                ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Common Help',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          ...faqs.entries.map(
            (faq) => Card(
              child: ExpansionTile(
                title: Text(faq.key),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(faq.value),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AddressScreen extends StatefulWidget {
  final Map<String, dynamic>? initialAddress;
  final String? mobileNumber;
  final String? customerName;
  final FirebasePhoneAuthService? authService;
  final bool returnAddress;
  final bool? currentLocationServiceable;
  final String? currentLocationArea;

  const AddressScreen({
    super.key,
    this.initialAddress,
    this.mobileNumber,
    this.customerName,
    this.authService,
    this.returnAddress = false,
    this.currentLocationServiceable,
    this.currentLocationArea,
  });

  @override
  State<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends State<AddressScreen> {
  final houseController = TextEditingController();
  final areaController = TextEditingController();
  final pincodeController = TextEditingController();
  final landmarkController = TextEditingController();
  late final FirebasePhoneAuthService _authService;
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? FirebasePhoneAuthService();
    final address = widget.initialAddress;
    if (address != null) {
      houseController.text = address['house']?.toString() ?? '';
      areaController.text = address['area']?.toString() ?? '';
      pincodeController.text = address['pincode']?.toString() ?? '';
      landmarkController.text = address['landmark']?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    houseController.dispose();
    areaController.dispose();
    pincodeController.dispose();
    landmarkController.dispose();
    super.dispose();
  }

  bool _isAddressServiceableForForm(Map<String, dynamic> address) {
    final area = (address['area'] ?? '').toString().trim().toLowerCase();
    final pincode = (address['pincode'] ?? '').toString().trim();
    print('ADDRESS AREA: $area');
    print('ADDRESS PINCODE: $pincode');
    final isServiceable = _isAddressServiceable(address);
    print(isServiceable ? 'ADDRESS SERVICEABLE = TRUE' : 'NOT SERVICEABLE');
    return isServiceable;
  }

  Future<void> saveAddress() async {
    if (houseController.text.trim().isEmpty ||
        areaController.text.trim().isEmpty ||
        !RegExp(r'^\d{6}$').hasMatch(pincodeController.text.trim()) ||
        landmarkController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter your house/flat, area, landmark, and a valid 6-digit pincode.',
          ),
        ),
      );
      return;
    }
    final existingName =
        widget.initialAddress?['name']?.toString().trim() ?? '';
    final recipientName =
        existingName.isNotEmpty
            ? existingName
            : (widget.customerName ?? currentCustomerName).trim();
    final existingAddressMobile =
        widget.initialAddress?['mobile']?.toString().trim() ?? '';
    final suppliedMobile = widget.mobileNumber?.trim() ?? '';
    final recipientMobile =
        existingAddressMobile.isNotEmpty
            ? existingAddressMobile
            : suppliedMobile.isNotEmpty
            ? suppliedMobile
            : (await _authService.getCurrentVerifiedMobileNumber() ??
                    currentCustomerMobile)
                .trim();
    final address = <String, dynamic>{
      ...?widget.initialAddress,
      'name': recipientName,
      'mobile': recipientMobile,
      'house': houseController.text.trim(),
      'area': areaController.text.trim(),
      'pincode': pincodeController.text.trim(),
      'landmark': landmarkController.text.trim(),
    };

    setState(() => isSaving = true);
    final isServiceable = _isAddressServiceableForForm(address);
    if (!mounted) return;
    if (!isServiceable) {
      setState(() => isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not delivering in your locality.')),
      );
      return;
    }

    setState(() => isSaving = true);
    try {
      final savedAddress = await _authService.saveCustomerAddress(
        address,
        makeDefault: widget.initialAddress?['id'] == null,
      );
      if (!mounted) return;
      saveCustomerAddress(savedAddress);

      if (widget.returnAddress) {
        Navigator.pop(context, savedAddress);
      } else if (widget.initialAddress != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder:
                (context) => HomeScreen(
                  authService: _authService,
                  customerName: recipientName,
                  deliveryAddress: savedAddress,
                  mobileNumber: recipientMobile,
                  currentLocationServiceable: widget.currentLocationServiceable,
                  currentLocationArea: widget.currentLocationArea,
                ),
          ),
        );
      } else {
        Navigator.pop(context, savedAddress);
      }
    } on FirebaseCustomerProfileException catch (exception) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(exception.message)));
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery Address')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (widget.initialAddress?['latitude'] != null &&
                  widget.initialAddress?['longitude'] != null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Detected location: '
                    '${(widget.initialAddress!['latitude'] as num).toStringAsFixed(6)}, '
                    '${(widget.initialAddress!['longitude'] as num).toStringAsFixed(6)}',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: houseController,
                decoration: const InputDecoration(
                  labelText: 'House / Flat Number',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: areaController,
                decoration: const InputDecoration(
                  labelText: 'City / Town',
                  hintText: 'Karjat',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: pincodeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Pincode',
                  hintText: 'Karjat pincode: 410201',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: landmarkController,
                decoration: const InputDecoration(
                  labelText: 'Landmark',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),

              ElevatedButton(
                onPressed: isSaving ? null : saveAddress,
                child: Text(isSaving ? 'CHECKING ADDRESS...' : 'SAVE ADDRESS'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProductDetailsScreen extends StatefulWidget {
  final Product product;
  final VoidCallback onAddToCart;

  const ProductDetailsScreen({
    super.key,
    required this.product,
    required this.onAddToCart,
  });

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  int quantity = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Product Details'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Icon(widget.product.icon, size: 150, color: Colors.green),
            ),
            const SizedBox(height: 25),
            Text(
              widget.product.name,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              widget.product.brand,
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 15),
            Text(
              '₹${widget.product.price.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Product Description',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Fresh and quality grocery product suitable for your daily needs.',
              style: TextStyle(fontSize: 16),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () {
                    if (quantity > 1) {
                      setState(() {
                        quantity--;
                      });
                    }
                  },
                  icon: const Icon(Icons.remove),
                ),
                Text(
                  '$quantity',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      quantity++;
                    });
                  },
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Text(
              'Total: ₹${(widget.product.price * quantity).toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  for (int i = 0; i < quantity; i++) {
                    widget.onAddToCart();
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$quantity item(s) added to cart')),
                  );

                  Navigator.pop(context);
                },
                child: const Text('ADD TO CART'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
