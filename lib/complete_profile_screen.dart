import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'firebase_phone_auth_service.dart';

class CompleteProfileScreen extends StatefulWidget {
  final FirebasePhoneAuthService authService;
  final Map<String, dynamic> initialCustomerProfile;
  final Future<void> Function()? onLogout;

  const CompleteProfileScreen({
    super.key,
    required this.authService,
    required this.initialCustomerProfile,
    this.onLogout,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  static const _brandGreen = Color(0xff075b38);
  static const _actionGreen = Color(0xff079447);

  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _imagePicker = ImagePicker();
  Uint8List? _selectedPhotoBytes;
  bool _isSaving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _fullNameController.text =
        widget.initialCustomerProfile['fullName']?.toString() ?? '';
    _emailController.text =
        widget.initialCustomerProfile['email']?.toString() ?? '';
  }

  Future<void> _pickPhoto() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      setState(() => _selectedPhotoBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to open that photo. Please try again.'),
        ),
      );
    }
  }

  Future<void> _saveProfile() async {
    if (_isSaving) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    final email = _emailController.text.trim();
    try {
      await widget.authService.updateCustomerProfile(
        fullName: _fullNameController.text.trim(),
        email: email.isEmpty ? null : email,
      );
      if (!mounted) return;
      Navigator.of(context).pop(_fullNameController.text.trim());
    } on FirebaseCustomerProfileException catch (exception) {
      if (mounted) setState(() => _saveError = exception.message);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _saveError = 'We could not save your profile. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _photoContents(String? photoUrl) {
    if (_selectedPhotoBytes case final bytes?) {
      return Image.memory(bytes, fit: BoxFit.cover, width: 104, height: 104);
    }
    if (photoUrl != null && photoUrl.trim().isNotEmpty) {
      return Image.network(
        photoUrl,
        fit: BoxFit.cover,
        width: 104,
        height: 104,
        errorBuilder: (context, error, stackTrace) => _photoPlaceholder(),
      );
    }
    return _photoPlaceholder();
  }

  Widget _photoPlaceholder() => const ColoredBox(
    color: Color(0xffe8f4ec),
    child: Center(
      child: Icon(Icons.person_outline, color: _brandGreen, size: 48),
    ),
  );

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phoneNumber = FirebaseAuth.instance.currentUser?.phoneNumber;
    final photoUrl = widget.initialCustomerProfile['profilePhoto']?.toString();

    return Scaffold(
      backgroundColor: const Color(0xfff7faf7),
      appBar: AppBar(
        backgroundColor: const Color(0xfff7faf7),
        elevation: 0,
        actions: [
          if (widget.onLogout != null)
            IconButton(
              tooltip: 'Log out',
              onPressed: _isSaving ? null : widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder:
              (context, constraints) => SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Image.asset(
                              'assets/images/karjatcart_logo.png',
                              width: 90,
                              height: 74,
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Complete Your Profile',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _brandGreen,
                              fontSize: 25,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            "Let's get to know you better",
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xff63736a),
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Center(
                            child: Column(
                              children: [
                                Container(
                                  width: 112,
                                  height: 112,
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xffc9dfcf),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: ClipOval(
                                    child: _photoContents(photoUrl),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  onPressed: _isSaving ? null : _pickPhoto,
                                  icon: const Icon(
                                    Icons.add_a_photo_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _selectedPhotoBytes != null ||
                                            (photoUrl?.trim().isNotEmpty ??
                                                false)
                                        ? 'Change Photo'
                                        : 'Add Photo',
                                  ),
                                  style: TextButton.styleFrom(
                                    foregroundColor: _brandGreen,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          _fieldLabel('Full Name *'),
                          TextFormField(
                            controller: _fullNameController,
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.name],
                            decoration: _inputDecoration(
                              'Enter your full name',
                            ),
                            validator: (value) {
                              if ((value ?? '').trim().length < 2) {
                                return 'Please enter a name with at least 2 characters.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 18),
                          _fieldLabel('Mobile Number'),
                          TextFormField(
                            initialValue: phoneNumber ?? '',
                            readOnly: true,
                            keyboardType: TextInputType.phone,
                            decoration: _inputDecoration('').copyWith(
                              suffixIcon: const Padding(
                                padding: EdgeInsets.only(right: 12),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.verified,
                                      color: _actionGreen,
                                      size: 17,
                                    ),
                                    SizedBox(width: 5),
                                    Text(
                                      'Verified',
                                      style: TextStyle(
                                        color: _actionGreen,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              filled: true,
                              fillColor: const Color(0xffedf2ee),
                            ),
                          ),
                          const SizedBox(height: 18),
                          _fieldLabel('Email (Optional)'),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.email],
                            onFieldSubmitted: (_) => _saveProfile(),
                            decoration: _inputDecoration(
                              'Enter your email address',
                            ),
                            validator: (value) {
                              final email = (value ?? '').trim();
                              if (email.isNotEmpty &&
                                  !RegExp(
                                    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                  ).hasMatch(email)) {
                                return 'Please enter a valid email address.';
                              }
                              return null;
                            },
                          ),
                          if (_saveError != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              _saveError!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xffb3261e)),
                            ),
                          ],
                          const SizedBox(height: 24),
                          SizedBox(
                            height: 54,
                            child: ElevatedButton(
                              onPressed: _isSaving ? null : _saveProfile,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _actionGreen,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: const Color(
                                  0xff9ab8a4,
                                ),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child:
                                  _isSaving
                                      ? const SizedBox.square(
                                        dimension: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                      : const Text(
                                        'Continue',
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                            ),
                          ),
                          if (_selectedPhotoBytes != null) ...[
                            const SizedBox(height: 9),
                            const Text(
                              'Photo preview only. Photo uploads will be available later.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xff63736a),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }

  Widget _fieldLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      label,
      style: const TextStyle(
        color: Color(0xff26352b),
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    hintText: hint.isEmpty ? null : hint,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffd8e1da)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffd8e1da)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _actionGreen, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffb3261e)),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffb3261e), width: 1.5),
    ),
  );
}
