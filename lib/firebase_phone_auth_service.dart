import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class FirebasePhoneAuthException implements Exception {
  final String message;
  final String? code;
  final String? plugin;

  const FirebasePhoneAuthException(this.message, {this.code, this.plugin});

  String get debugMessage {
    final details = [
      if (code != null) 'Firebase error code: $code',
      'Firebase error message: $message',
      if (plugin != null) 'Firebase error plugin: $plugin',
    ];
    return details.join('\n');
  }

  @override
  String toString() => message;
}

class FirebaseCustomerProfileException implements Exception {
  final String message;

  const FirebaseCustomerProfileException(this.message);

  @override
  String toString() => message;
}

class FirebaseGoogleSignInException implements Exception {
  final String message;
  final String? code;

  const FirebaseGoogleSignInException(this.message, {this.code});

  @override
  String toString() => message;
}

enum GoogleSignInResult { directLogin, phoneVerification }

class FirebasePhoneAuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  static Future<void>? _googleSignInInitialization;

  String? _verificationId;
  ConfirmationResult? _confirmationResult;
  Future<UserCredential>? _automaticSignIn;
  OAuthCredential? _pendingGoogleCredential;
  String? _pendingGoogleUserId;
  String? _pendingGoogleEmail;
  Timer? _pendingGoogleCredentialExpiry;
  int _googlePhoneOperationsInProgress = 0;
  Completer<void>? _googlePhoneOperationsIdle;
  bool _clearPendingGoogleCredentialWhenIdle = false;
  String? _googlePhoneVerificationId;
  ConfirmationResult? _googlePhoneConfirmationResult;
  Future<UserCredential>? _googlePhoneSignInInProgress;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  bool get hasPendingGoogleCredential => _pendingGoogleCredential != null;

  Future<GoogleSignInResult?> signInWithGoogle() async {
    final activeGooglePhoneOperation = _googlePhoneOperationsIdle?.future;
    if (activeGooglePhoneOperation != null) {
      await activeGooglePhoneOperation;
    }
    _clearPendingGoogleCredential();
    try {
      await (_googleSignInInitialization ??=
          GoogleSignIn.instance.initialize());
      final googleAccount = await GoogleSignIn.instance.authenticate();
      final idToken = googleAccount.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const FirebaseGoogleSignInException(
          'Google Sign-In did not return an ID token.',
        );
      }

      _pendingGoogleCredential = GoogleAuthProvider.credential(
        idToken: idToken,
      );
      _pendingGoogleUserId = googleAccount.id;
      _pendingGoogleEmail = googleAccount.email;
      _pendingGoogleCredentialExpiry = Timer(
        const Duration(minutes: 10),
        _clearPendingGoogleCredential,
      );

      final callableResult = await FirebaseFunctions.instance
          .httpsCallable('resolveGoogleIdentity')
          .call({'googleIdToken': idToken});
      final response = callableResult.data;
      if (response is! Map ||
          response['success'] is! bool ||
          response['route'] is! String) {
        throw const FirebaseGoogleSignInException(
          'Google sign-in could not be completed. Please try again.',
        );
      }

      final success = response['success'] as bool;
      final route = response['route'] as String;
      if (!success && route == 'phone_verification') {
        if (_pendingGoogleCredential == null) {
          throw const FirebaseGoogleSignInException(
            'Your Google sign-in has expired. Please sign in again.',
          );
        }
        return GoogleSignInResult.phoneVerification;
      }

      if (!success && route == 'not_eligible') {
        _clearPendingGoogleCredential();
        throw const FirebaseGoogleSignInException(
          'This Google account cannot be used for direct KarjatCart login. '
          'Verify a phone number or contact support for account recovery.',
        );
      }

      if (success && route == 'direct_login') {
        final customToken = response['customToken'];
        if (customToken is! String || customToken.trim().isEmpty) {
          throw const FirebaseGoogleSignInException(
            'Google sign-in could not be completed. Please try again.',
          );
        }

        _pendingGoogleCredentialExpiry?.cancel();
        _pendingGoogleCredentialExpiry = null;
        final userCredential = await _auth.signInWithCustomToken(
          customToken.trim(),
        );
        final signedInUser = userCredential.user;
        final isExpectedGoogleUser =
            signedInUser != null &&
            signedInUser.providerData.any(
              (provider) =>
                  provider.providerId == GoogleAuthProvider.PROVIDER_ID &&
                  provider.uid == googleAccount.id,
            );
        if (signedInUser == null ||
            _auth.currentUser?.uid != signedInUser.uid ||
            !isExpectedGoogleUser ||
            signedInUser.phoneNumber?.trim().isNotEmpty != true) {
          await _auth.signOut();
          throw const FirebaseGoogleSignInException(
            'Google sign-in could not be verified. Please try again.',
          );
        }

        await FirebaseFirestore.instance
            .collection('customers')
            .doc(signedInUser.uid)
            .update({
              'lastLoginAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });

        _clearPendingGoogleCredential();
        return GoogleSignInResult.directLogin;
      }

      throw const FirebaseGoogleSignInException(
        'Google sign-in could not be completed. Please try again.',
      );
    } on GoogleSignInException catch (exception) {
      _clearPendingGoogleCredential();
      if (exception.code == GoogleSignInExceptionCode.canceled) return null;
      throw FirebaseGoogleSignInException(
        exception.description?.trim().isNotEmpty == true
            ? exception.description!.trim()
            : 'Google Sign-In failed (${exception.code.name}).',
        code: exception.code.name,
      );
    } on FirebaseGoogleSignInException {
      _clearPendingGoogleCredential();
      rethrow;
    } on FirebaseFunctionsException {
      _clearPendingGoogleCredential();
      throw const FirebaseGoogleSignInException(
        'Unable to verify your Google account. Please check your connection and try again.',
      );
    } on FirebaseAuthException {
      _clearPendingGoogleCredential();
      throw const FirebaseGoogleSignInException(
        'Google sign-in could not be completed. Please try again.',
      );
    } catch (_) {
      _clearPendingGoogleCredential();
      throw const FirebaseGoogleSignInException(
        'Google sign-in could not be completed. Please try again.',
      );
    }
  }

  void clearPendingGoogleSignIn() {
    if (_googlePhoneOperationsInProgress > 0) {
      _clearPendingGoogleCredentialWhenIdle = true;
      return;
    }
    _clearPendingGoogleCredential();
  }

  Future<void> linkPendingGoogleToCurrentPhoneUser() async {
    final user = _auth.currentUser;
    if (user == null || user.phoneNumber?.trim().isNotEmpty != true) {
      throw const FirebasePhoneAuthException(
        'Verify your mobile number before linking Google.',
      );
    }
    _beginGooglePhoneOperation();
    try {
      await _linkGoogleCredentialToPhoneUser(user);
    } finally {
      _endGooglePhoneOperation();
    }
  }

  void _clearPendingGoogleCredential() {
    _pendingGoogleCredentialExpiry?.cancel();
    _pendingGoogleCredentialExpiry = null;
    _pendingGoogleCredential = null;
    _pendingGoogleUserId = null;
    _pendingGoogleEmail = null;
    _googlePhoneVerificationId = null;
    _googlePhoneConfirmationResult = null;
    _googlePhoneSignInInProgress = null;
  }

  void _beginGooglePhoneOperation() {
    _pendingGoogleCredentialExpiry?.cancel();
    _pendingGoogleCredentialExpiry = null;
    if (_googlePhoneOperationsInProgress == 0) {
      _googlePhoneOperationsIdle = Completer<void>();
    }
    _googlePhoneOperationsInProgress++;
  }

  void _endGooglePhoneOperation() {
    _googlePhoneOperationsInProgress--;
    if (_googlePhoneOperationsInProgress != 0) return;

    if (_clearPendingGoogleCredentialWhenIdle) {
      _clearPendingGoogleCredentialWhenIdle = false;
      _clearPendingGoogleCredential();
    }
    final idleCompleter = _googlePhoneOperationsIdle;
    _googlePhoneOperationsIdle = null;
    if (idleCompleter != null && !idleCompleter.isCompleted) {
      idleCompleter.complete();
    }
  }

  Future<void> sendOtp(
    String input, {
    required VoidCallback onCodeSent,
    required ValueChanged<FirebaseCustomerProfileException>
    onProfilePersistenceError,
  }) async {
    final phoneNumber = normalizeIndianPhoneNumber(input);

    if (phoneNumber == null) {
      throw const FirebasePhoneAuthException(
        'Please enter a valid 10-digit Indian mobile number.',
      );
    }

    _verificationId = null;
    _confirmationResult = null;
    _automaticSignIn = null;
    _clearWebVerifier();

    try {
      if (kIsWeb) {
        _confirmationResult = await _auth.signInWithPhoneNumber(phoneNumber);
        onCodeSent();
        return;
      }

      final completer = Completer<void>();
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        verificationCompleted: (credential) async {
          _automaticSignIn = _auth.signInWithCredential(credential);
          try {
            await _automaticSignIn;
          } catch (_) {
            // The manual OTP path remains available if automatic verification fails.
            return;
          }
          try {
            await _upsertCustomerProfile();
          } on FirebaseCustomerProfileException catch (exception) {
            onProfilePersistenceError(exception);
          }
        },
        verificationFailed: (exception) {
          _logFirebaseAuthException(exception);
          if (!completer.isCompleted) {
            completer.completeError(
              FirebasePhoneAuthException(
                _messageForCode(exception.code),
                code: exception.code,
                plugin: exception.plugin,
              ),
            );
          }
        },
        codeSent: (verificationId, resendToken) {
          _verificationId = verificationId;
          onCodeSent();
          if (!completer.isCompleted) completer.complete();
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _verificationId ??= verificationId;
          if (!completer.isCompleted) completer.complete();
        },
      );
      await completer.future;
    } on FirebasePhoneAuthException {
      rethrow;
    } on FirebaseAuthException catch (exception) {
      _clearWebVerifier();
      _logFirebaseAuthException(exception);
      throw FirebasePhoneAuthException(
        _messageForCode(exception.code),
        code: exception.code,
        plugin: exception.plugin,
      );
    } catch (_) {
      _clearWebVerifier();
      throw const FirebasePhoneAuthException(
        'Unable to send OTP. Please check your connection and try again.',
      );
    }
  }

  Future<void> sendGooglePhoneVerificationOtp(
    String input, {
    required VoidCallback onCodeSent,
    required VoidCallback onAutoVerified,
    required ValueChanged<FirebasePhoneAuthException> onAutoVerificationError,
  }) async {
    final phoneNumber = normalizeIndianPhoneNumber(input);
    if (phoneNumber == null) {
      throw const FirebasePhoneAuthException(
        'Please enter a valid 10-digit Indian mobile number.',
      );
    }

    if (_pendingGoogleCredential == null) {
      throw const FirebasePhoneAuthException(
        'Your Google sign-in has expired. Please sign in again.',
      );
    }
    _pendingGoogleCredentialExpiry?.cancel();
    _pendingGoogleCredentialExpiry = null;
    _googlePhoneVerificationId = null;
    _googlePhoneConfirmationResult = null;
    _googlePhoneSignInInProgress = null;

    if (kIsWeb) {
      try {
        _googlePhoneConfirmationResult = await _auth.signInWithPhoneNumber(
          phoneNumber,
        );
        onCodeSent();
        return;
      } on FirebaseAuthException catch (exception) {
        _logFirebaseAuthException(exception);
        _clearPendingGoogleCredential();
        throw _phoneAuthException(exception);
      } catch (_) {
        _clearPendingGoogleCredential();
        throw const FirebasePhoneAuthException(
          'Unable to send verification code. Please try again.',
        );
      }
    }

    final requestCompleter = Completer<void>();

    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        verificationCompleted: (credential) async {
          try {
            await _completeGooglePhoneSignIn(credential);
            onAutoVerified();
            if (!requestCompleter.isCompleted) requestCompleter.complete();
          } on FirebasePhoneAuthException catch (exception) {
            if (!requestCompleter.isCompleted) {
              requestCompleter.completeError(exception);
            } else {
              onAutoVerificationError(exception);
            }
          } catch (_) {
            _clearPendingGoogleCredential();
            final phoneException = const FirebasePhoneAuthException(
              'Unable to complete phone verification. Please try again.',
            );
            if (!requestCompleter.isCompleted) {
              requestCompleter.completeError(phoneException);
            } else {
              onAutoVerificationError(phoneException);
            }
          }
        },
        verificationFailed: (exception) {
          _logFirebaseAuthException(exception);
          _clearPendingGoogleCredential();
          final phoneException = _phoneAuthException(exception);
          if (!requestCompleter.isCompleted) {
            requestCompleter.completeError(phoneException);
          } else {
            onAutoVerificationError(phoneException);
          }
        },
        codeSent: (verificationId, resendToken) {
          _googlePhoneVerificationId = verificationId;
          onCodeSent();
          if (!requestCompleter.isCompleted) requestCompleter.complete();
        },
        codeAutoRetrievalTimeout: (verificationId) {
          _googlePhoneVerificationId ??= verificationId;
          if (!requestCompleter.isCompleted) requestCompleter.complete();
        },
      );
      await requestCompleter.future;
    } on FirebasePhoneAuthException {
      rethrow;
    } on FirebaseAuthException catch (exception) {
      _logFirebaseAuthException(exception);
      _clearPendingGoogleCredential();
      throw _phoneAuthException(exception);
    } catch (_) {
      _clearPendingGoogleCredential();
      throw const FirebasePhoneAuthException(
        'Unable to send verification code. Please try again.',
      );
    }
  }

  Future<UserCredential> verifyGooglePhoneOtp(String smsCode) async {
    if (!RegExp(r'^\d{6}$').hasMatch(smsCode.trim())) {
      throw const FirebasePhoneAuthException(
        'Invalid OTP. Please enter the 6-digit code sent to your phone.',
      );
    }

    if (_pendingGoogleCredential == null) {
      throw const FirebasePhoneAuthException(
        'Your Google sign-in has expired. Please sign in again.',
      );
    }
    final inProgress = _googlePhoneSignInInProgress;
    if (inProgress != null) return inProgress;

    _beginGooglePhoneOperation();
    try {
      late final UserCredential phoneResult;
      if (kIsWeb) {
        final confirmationResult = _googlePhoneConfirmationResult;
        if (confirmationResult == null) {
          throw const FirebasePhoneAuthException(
            'Your OTP session has expired. Please request a new OTP.',
          );
        }
        phoneResult = await confirmationResult.confirm(smsCode.trim());
      } else {
        final verificationId = _googlePhoneVerificationId;
        if (verificationId == null) {
          throw const FirebasePhoneAuthException(
            'Your OTP session has expired. Please request a new OTP.',
          );
        }
        final phoneCredential = PhoneAuthProvider.credential(
          verificationId: verificationId,
          smsCode: smsCode.trim(),
        );
        phoneResult = await _completeGooglePhoneSignIn(phoneCredential);
      }

      if (kIsWeb) {
        return _linkGoogleToPhoneUser(phoneResult);
      }
      return phoneResult;
    } on FirebaseAuthException catch (exception) {
      _logFirebaseAuthException(exception);
      _clearPendingGoogleCredential();
      throw _phoneAuthException(exception);
    } finally {
      _endGooglePhoneOperation();
    }
  }

  Future<UserCredential> _completeGooglePhoneSignIn(
    PhoneAuthCredential credential,
  ) async {
    final inProgress = _googlePhoneSignInInProgress;
    if (inProgress != null) return inProgress;

    _beginGooglePhoneOperation();
    final signIn = _performGooglePhoneSignIn(credential);
    _googlePhoneSignInInProgress = signIn;
    try {
      return await signIn;
    } finally {
      _googlePhoneSignInInProgress = null;
      _endGooglePhoneOperation();
    }
  }

  Future<UserCredential> _performGooglePhoneSignIn(
    PhoneAuthCredential credential,
  ) async {
    try {
      final phoneResult = await _auth.signInWithCredential(credential);
      return _linkGoogleToPhoneUser(phoneResult);
    } on FirebaseAuthException catch (exception) {
      _clearPendingGoogleCredential();
      throw _phoneAuthException(exception);
    }
  }

  Future<UserCredential> _linkGoogleToPhoneUser(
    UserCredential phoneResult,
  ) async {
    final phoneUser = _auth.currentUser;
    if (phoneUser == null || phoneResult.user?.uid != phoneUser.uid) {
      throw const FirebasePhoneAuthException(
        'Phone verification did not establish the expected customer account.',
      );
    }
    await _linkGoogleCredentialToPhoneUser(phoneUser, phoneResult: phoneResult);
    return phoneResult;
  }

  Future<void> _linkGoogleCredentialToPhoneUser(
    User phoneUser, {
    UserCredential? phoneResult,
  }) async {
    final googleCredential = _pendingGoogleCredential;
    final googleUserId = _pendingGoogleUserId;
    if (googleCredential == null || googleUserId == null) {
      throw const FirebasePhoneAuthException(
        'Google sign-in expired. Sign in with Google again to continue.',
      );
    }
    final canonicalUid = phoneUser.uid;

    try {
      User? linkedUser = phoneUser;
      try {
        final linkResult = await phoneUser.linkWithCredential(googleCredential);
        linkedUser = linkResult.user;
      } on FirebaseAuthException catch (exception) {
        if (exception.code == 'provider-already-linked') {
          try {
            await phoneUser.reload();
          } on FirebaseAuthException {
            _clearPendingGoogleCredential();
            throw const FirebasePhoneAuthException(
              'Unable to confirm the Google account already linked to this customer. '
              'Please sign in again.',
              code: 'google-provider-conflict',
            );
          }
          linkedUser = _auth.currentUser ?? phoneUser;
          final linkedGoogle = linkedUser.providerData.where(
            (provider) => provider.providerId == GoogleAuthProvider.PROVIDER_ID,
          );
          final matchingGoogle = linkedGoogle.any(
            (provider) => provider.uid == googleUserId,
          );
          if (!matchingGoogle) {
            _clearPendingGoogleCredential();
            throw const FirebasePhoneAuthException(
              'A different Google account is already linked to this customer. '
              'Contact support to recover access; accounts have not been merged.',
              code: 'google-provider-conflict',
            );
          }
        } else if (_isGoogleCredentialConflict(exception.code)) {
          _clearPendingGoogleCredential();
          throw const FirebasePhoneAuthException(
            'This Google account is already linked to another customer account. '
            'Your verified phone account remains active; accounts have not been merged.',
            code: 'google-credential-conflict',
          );
        } else {
          _clearPendingGoogleCredential();
          throw FirebasePhoneAuthException(
            'Unable to link Google to this phone account. Please try signing in again.',
            code: exception.code,
          );
        }
      }

      final currentUser = _auth.currentUser;
      if (linkedUser == null ||
          linkedUser.uid != canonicalUid ||
          phoneUser.uid != canonicalUid ||
          currentUser?.uid != canonicalUid ||
          (phoneResult != null && phoneResult.user?.uid != canonicalUid)) {
        _clearPendingGoogleCredential();
        throw const FirebasePhoneAuthException(
          'The customer account changed during Google linking. Please sign in again.',
          code: 'google-link-uid-mismatch',
        );
      }

      final phoneNumber = linkedUser.phoneNumber?.trim() ?? '';
      if (phoneNumber.isEmpty) {
        _clearPendingGoogleCredential();
        throw const FirebasePhoneAuthException(
          'Firebase did not confirm the verified phone number.',
        );
      }
      await _upsertGoogleLinkedCustomerProfile(
        linkedUser,
        phoneNumber: phoneNumber,
        googleEmail: _pendingGoogleEmail,
      );
      _clearPendingGoogleCredential();
    } on FirebasePhoneAuthException {
      rethrow;
    } on FirebaseException catch (exception) {
      _clearPendingGoogleCredential();
      debugPrint('CUSTOMER PROFILE FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      throw const FirebaseCustomerProfileException(
        'Unable to save customer profile. Please try again.',
      );
    } catch (_) {
      _clearPendingGoogleCredential();
      rethrow;
    }
  }

  static bool _isGoogleCredentialConflict(String code) =>
      code == 'credential-already-in-use' ||
      code == 'account-exists-with-different-credential' ||
      code == 'email-already-in-use';

  static String _stringField(Map<String, dynamic> data, String field) {
    final value = data[field];
    return value is String ? value.trim() : '';
  }

  static String? _firstNonEmptyString(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static bool _sameEmail(String first, String second) =>
      first.trim().isNotEmpty &&
      second.trim().isNotEmpty &&
      first.trim().toLowerCase() == second.trim().toLowerCase();

  List<String> _normalizedLoginMethods(
    Map<String, dynamic> data,
    User user, {
    required Iterable<String> authenticatedMethods,
  }) {
    final methods = <String>[];

    void addMethod(String? method) {
      final value = method?.trim() ?? '';
      if (value.isEmpty) return;
      final normalized = switch (value) {
        'phone' || 'mobile' => 'mobile',
        'google.com' || 'google' => 'google',
        'apple.com' || 'apple' => 'apple',
        _ => value,
      };
      if (!methods.contains(normalized)) methods.add(normalized);
    }

    final storedMethods = data['loginMethods'];
    if (storedMethods is List) {
      for (final method in storedMethods) {
        if (method is String) addMethod(method);
      }
    }
    if (data['loginMethod'] is String) {
      addMethod(data['loginMethod'] as String);
    }
    for (final provider in user.providerData) {
      addMethod(provider.providerId);
    }
    for (final method in authenticatedMethods) {
      addMethod(method);
    }
    return methods;
  }

  Future<void> _upsertGoogleLinkedCustomerProfile(
    User user, {
    required String phoneNumber,
    String? googleEmail,
  }) async {
    final customerRef = FirebaseFirestore.instance
        .collection('customers')
        .doc(user.uid);
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(customerRef);
      final data = snapshot.data() ?? <String, dynamic>{};
      final methods = _normalizedLoginMethods(
        data,
        user,
        authenticatedMethods: const ['mobile', 'google'],
      );
      final authEmail = user.email?.trim() ?? '';
      final providerEmail = _firstNonEmptyString([googleEmail, authEmail]);
      final existingEmail = _stringField(data, 'email');
      final profileEmail =
          existingEmail.isNotEmpty ? existingEmail : providerEmail ?? '';
      final authPhoto = user.photoURL?.trim() ?? '';
      final fullName = _stringField(data, 'fullName');
      final legacyName = _stringField(data, 'name');
      final displayName = user.displayName?.trim() ?? '';
      final verifiedPhone = phoneNumber.trim();

      if (snapshot.exists) {
        final fields = <String, dynamic>{
          'customerId': user.uid,
          'loginMethods': methods,
          'lastLoginAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'loginMethod': FieldValue.delete(),
        };
        if (verifiedPhone.isNotEmpty) {
          fields['mobileNumber'] = verifiedPhone;
          fields['isMobileVerified'] = true;
        }
        if (existingEmail.isEmpty && providerEmail != null) {
          fields['email'] = providerEmail;
        }
        if (_sameEmail(profileEmail, authEmail)) {
          fields['isEmailVerified'] = user.emailVerified;
        }
        if (fullName.isEmpty) {
          if (legacyName.isNotEmpty) {
            fields['fullName'] = legacyName;
          } else if (data['profileCompleted'] != true &&
              displayName.isNotEmpty) {
            fields['fullName'] = displayName;
          }
        }
        if (_stringField(data, 'profilePhoto').isEmpty &&
            authPhoto.isNotEmpty) {
          fields['profilePhoto'] = authPhoto;
        }
        transaction.set(customerRef, fields, SetOptions(merge: true));
        return;
      }

      transaction.set(customerRef, {
        'customerId': user.uid,
        'fullName': displayName,
        if (verifiedPhone.isNotEmpty) 'mobileNumber': verifiedPhone,
        if (providerEmail != null) 'email': providerEmail,
        if (authPhoto.isNotEmpty) 'profilePhoto': authPhoto,
        'loginMethods': methods,
        if (verifiedPhone.isNotEmpty) 'isMobileVerified': true,
        'isEmailVerified':
            _sameEmail(profileEmail, authEmail) && user.emailVerified,
        'accountStatus': 'active',
        'profileCompleted': false,
        'savedAddresses': <dynamic>[],
        'defaultAddressId': null,
        'notificationPreferences': <String, bool>{
          'orderUpdates': true,
          'deliveryUpdates': true,
          'promotions': false,
        },
        'marketingConsent': false,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  static FirebasePhoneAuthException _phoneAuthException(
    FirebaseAuthException exception,
  ) {
    return FirebasePhoneAuthException(
      _messageForCode(exception.code),
      code: exception.code,
      plugin: exception.plugin,
    );
  }

  Future<UserCredential> verifyOtp(
    String smsCode, {
    Stopwatch? diagnosticStopwatch,
  }) async {
    final loginStopwatch = diagnosticStopwatch ?? (Stopwatch()..start());
    if (!RegExp(r'^\d{6}$').hasMatch(smsCode.trim())) {
      throw const FirebasePhoneAuthException(
        'Invalid OTP. Please enter the 6-digit code sent to your phone.',
      );
    }

    try {
      if (kIsWeb) {
        final confirmationResult = _confirmationResult;
        _logLoginStep(
          'LOGIN STEP: OTP CONFIRM START',
          loginStopwatch,
          detail: 'confirmationResultIsNull=${confirmationResult == null}',
        );
        if (confirmationResult == null) {
          throw const FirebasePhoneAuthException(
            'Your OTP session has expired. Please request a new OTP.',
          );
        }
        late final UserCredential credential;
        try {
          credential = await confirmationResult.confirm(smsCode.trim());
          _logLoginStep('LOGIN STEP: OTP CONFIRM SUCCESS', loginStopwatch);
        } catch (exception, stackTrace) {
          _logLoginException(
            'LOGIN STEP: OTP CONFIRM ERROR',
            loginStopwatch,
            exception,
            stackTrace,
          );
          rethrow;
        }
        _clearWebVerifier();
        await _upsertCustomerProfileWithDiagnostics(loginStopwatch);
        return credential;
      }

      final verificationId = _verificationId;
      if (verificationId == null) {
        throw const FirebasePhoneAuthException(
          'Your OTP session has expired. Please request a new OTP.',
        );
      }

      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
      _logLoginStep(
        'LOGIN STEP: OTP CONFIRM START',
        loginStopwatch,
        detail: 'confirmationResultIsNull=not-applicable',
      );
      late final UserCredential userCredential;
      try {
        userCredential = await _auth.signInWithCredential(credential);
        _logLoginStep('LOGIN STEP: OTP CONFIRM SUCCESS', loginStopwatch);
      } catch (exception, stackTrace) {
        _logLoginException(
          'LOGIN STEP: OTP CONFIRM ERROR',
          loginStopwatch,
          exception,
          stackTrace,
        );
        rethrow;
      }
      await _upsertCustomerProfileWithDiagnostics(loginStopwatch);
      return userCredential;
    } on FirebasePhoneAuthException {
      rethrow;
    } on FirebaseCustomerProfileException {
      rethrow;
    } on FirebaseAuthException catch (exception) {
      _clearWebVerifier();
      _logFirebaseAuthException(exception);
      throw FirebasePhoneAuthException(
        _messageForCode(exception.code),
        code: exception.code,
        plugin: exception.plugin,
      );
    } catch (_) {
      _clearWebVerifier();
      throw const FirebasePhoneAuthException(
        'Unable to verify OTP. Please try again.',
      );
    }
  }

  Future<void> _upsertCustomerProfileWithDiagnostics(
    Stopwatch loginStopwatch,
  ) async {
    _logLoginStep('LOGIN STEP: PROFILE UPSERT START', loginStopwatch);
    try {
      await _upsertCustomerProfile(loginStopwatch);
      _logLoginStep('LOGIN STEP: PROFILE UPSERT COMPLETE', loginStopwatch);
    } catch (exception, stackTrace) {
      _logLoginException(
        'LOGIN STEP: PROFILE UPSERT ERROR',
        loginStopwatch,
        exception,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _upsertCustomerProfile([Stopwatch? diagnosticStopwatch]) async {
    final loginStopwatch = diagnosticStopwatch ?? (Stopwatch()..start());
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('CUSTOMER PROFILE ERROR: Firebase Auth currentUser is NULL');
      throw const FirebaseCustomerProfileException(
        'Unable to save customer profile. Please try again.',
      );
    }

    final customerPath = 'customers/${user.uid}';

    debugPrint('CUSTOMER PROFILE UID: ${user.uid}');
    debugPrint('CUSTOMER PROFILE PATH: $customerPath');

    try {
      final customerRef = FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid);
      _logLoginStep('LOGIN STEP: PROFILE UPSERT GET START', loginStopwatch);
      final customerSnapshot = await customerRef.get();
      _logLoginStep('LOGIN STEP: PROFILE UPSERT GET COMPLETE', loginStopwatch);
      final existingData = customerSnapshot.data() ?? <String, dynamic>{};
      final isNewCustomer = !customerSnapshot.exists;
      final loginMethods = _normalizedLoginMethods(
        existingData,
        user,
        authenticatedMethods: const ['mobile'],
      );
      final verifiedPhone = user.phoneNumber?.trim() ?? '';
      final authEmail = user.email?.trim() ?? '';
      final existingEmail = _stringField(existingData, 'email');
      final profileEmail = existingEmail.isNotEmpty ? existingEmail : authEmail;
      final authPhoto = user.photoURL?.trim() ?? '';
      final existingFullName = _stringField(existingData, 'fullName');
      final legacyName = _stringField(existingData, 'name');
      final displayName = user.displayName?.trim() ?? '';
      final profileFields = <String, dynamic>{
        'customerId': user.uid,
        'loginMethods': loginMethods,
        'lastLoginAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'loginMethod': FieldValue.delete(),
        if (verifiedPhone.isNotEmpty) 'mobileNumber': verifiedPhone,
        if (verifiedPhone.isNotEmpty) 'isMobileVerified': true,
        if (!isNewCustomer && existingEmail.isEmpty && authEmail.isNotEmpty)
          'email': authEmail,
        if (!isNewCustomer && _sameEmail(profileEmail, authEmail))
          'isEmailVerified': user.emailVerified,
        if (!isNewCustomer && existingFullName.isEmpty && legacyName.isNotEmpty)
          'fullName': legacyName,
        if (!isNewCustomer &&
            existingFullName.isEmpty &&
            legacyName.isEmpty &&
            existingData['profileCompleted'] != true &&
            displayName.isNotEmpty)
          'fullName': displayName,
        if (_stringField(existingData, 'profilePhoto').isEmpty &&
            authPhoto.isNotEmpty)
          'profilePhoto': authPhoto,
        if (isNewCustomer) ...{
          'fullName': displayName,
          'isEmailVerified': authEmail.isNotEmpty && user.emailVerified,
          'accountStatus': 'active',
          'profileCompleted': false,
          'createdAt': FieldValue.serverTimestamp(),
          'savedAddresses': <dynamic>[],
          'defaultAddressId': null,
          'notificationPreferences': <String, bool>{
            'orderUpdates': true,
            'deliveryUpdates': true,
            'promotions': false,
          },
          'marketingConsent': false,
        },
      };

      _logLoginStep('LOGIN STEP: PROFILE UPSERT SET START', loginStopwatch);
      await customerRef.set(profileFields, SetOptions(merge: true));
      _logLoginStep('LOGIN STEP: PROFILE UPSERT SET COMPLETE', loginStopwatch);
      debugPrint('CUSTOMER PROFILE UPSERT SUCCESS: $customerPath');
    } on FirebaseException catch (exception, stackTrace) {
      _logLoginException(
        'LOGIN STEP: PROFILE UPSERT ERROR',
        loginStopwatch,
        exception,
        stackTrace,
      );
      debugPrint('CUSTOMER PROFILE FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to save customer profile. Please try again.',
      );
    } catch (exception, stackTrace) {
      _logLoginException(
        'LOGIN STEP: PROFILE UPSERT ERROR',
        loginStopwatch,
        exception,
        stackTrace,
      );
      debugPrint('CUSTOMER PROFILE ERROR: $exception');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to save customer profile. Please try again.',
      );
    }
  }

  Future<void> updateCustomerProfile({
    required String fullName,
    String? email,
    String? profilePhoto,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const FirebaseCustomerProfileException(
        'You must be signed in to update your profile.',
      );
    }

    final trimmedFullName = fullName.trim();
    if (trimmedFullName.length < 2) {
      throw const FirebaseCustomerProfileException(
        'Full name must contain at least 2 characters.',
      );
    }
    final trimmedEmail = email?.trim();

    final profileFields = <String, dynamic>{
      'fullName': trimmedFullName,
      'profileCompleted': true,
      if (trimmedEmail?.isNotEmpty == true) 'email': trimmedEmail,
      if (profilePhoto?.trim().isNotEmpty == true)
        'profilePhoto': profilePhoto!.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid)
          .update(profileFields);
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER PROFILE FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to save customer profile. Please try again.',
      );
    }
  }

  Future<Map<String, dynamic>?> getCurrentCustomerProfile() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    try {
      final snapshot =
          await FirebaseFirestore.instance
              .collection('customers')
              .doc(user.uid)
              .get();
      return snapshot.data();
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER PROFILE FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to load customer profile. Please try again.',
      );
    }
  }

  Future<String?> getCurrentVerifiedMobileNumber() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final authPhoneNumber = user.phoneNumber?.trim() ?? '';
    if (authPhoneNumber.isNotEmpty) return authPhoneNumber;

    try {
      final snapshot =
          await FirebaseFirestore.instance
              .collection('customers')
              .doc(user.uid)
              .get();
      final customerPhoneNumber =
          snapshot.data()?['mobileNumber']?.toString().trim() ?? '';
      return customerPhoneNumber.isEmpty ? null : customerPhoneNumber;
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER MOBILE FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to load the verified mobile number. Please try again.',
      );
    }
  }

  List<Map<String, dynamic>> _savedAddressesFrom(Map<String, dynamic> data) {
    final rawAddresses = data['savedAddresses'];
    if (rawAddresses is! List) return <Map<String, dynamic>>[];
    return rawAddresses
        .whereType<Map>()
        .map((address) => Map<String, dynamic>.from(address))
        .toList();
  }

  String? _defaultAddressIdFrom(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> addresses,
  ) {
    final storedId = data['defaultAddressId'];
    if (storedId is String &&
        addresses.any((address) => address['id']?.toString() == storedId)) {
      return storedId;
    }
    for (final address in addresses) {
      if (address['isDefault'] == true && address['id'] != null) {
        return address['id'].toString();
      }
    }
    return null;
  }

  bool _syncLegacyDefaultFlags(
    List<Map<String, dynamic>> addresses,
    String? defaultAddressId,
  ) {
    var changed = false;
    for (final address in addresses) {
      if (!address.containsKey('isDefault')) continue;
      final shouldBeDefault =
          defaultAddressId != null &&
          address['id']?.toString() == defaultAddressId;
      if (address['isDefault'] != shouldBeDefault) {
        address['isDefault'] = shouldBeDefault;
        changed = true;
      }
    }
    return changed;
  }

  Future<Map<String, dynamic>> loadCustomerAddressData() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {'addresses': <Map<String, dynamic>>[], 'defaultAddressId': null};
    }

    try {
      final customerRef = FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid);
      final snapshot = await customerRef.get();
      final data = snapshot.data() ?? <String, dynamic>{};
      final addresses = _savedAddressesFrom(data);
      var migratedAddressIds = false;
      for (final address in addresses) {
        if (address['id'] == null || address['id'].toString().isEmpty) {
          address['id'] = DateTime.now().microsecondsSinceEpoch.toString();
          migratedAddressIds = true;
        }
      }
      final defaultAddressId = _defaultAddressIdFrom(data, addresses);
      final legacyFlagsChanged = _syncLegacyDefaultFlags(
        addresses,
        defaultAddressId,
      );
      final storedDefaultAddressId = data['defaultAddressId'];
      if (migratedAddressIds ||
          legacyFlagsChanged ||
          storedDefaultAddressId != defaultAddressId) {
        await customerRef.update({
          'savedAddresses': addresses,
          'defaultAddressId': defaultAddressId,
        });
      }
      return {'addresses': addresses, 'defaultAddressId': defaultAddressId};
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER ADDRESS FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to load saved addresses. Please try again.',
      );
    }
  }

  Future<Map<String, dynamic>> saveCustomerAddress(
    Map<String, dynamic> address, {
    bool makeDefault = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const FirebaseCustomerProfileException(
        'You must be signed in to save an address.',
      );
    }

    try {
      final customerRef = FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid);
      final snapshot = await customerRef.get();
      if (!snapshot.exists) {
        throw const FirebaseCustomerProfileException(
          'Customer profile could not be found. Please sign in again.',
        );
      }
      final data = snapshot.data() ?? <String, dynamic>{};
      final addresses = _savedAddressesFrom(data);
      final addressCopy = Map<String, dynamic>.from(address);
      var addressId = addressCopy['id']?.toString();
      if (addressId == null || addressId.isEmpty) {
        addressId = DateTime.now().microsecondsSinceEpoch.toString();
      }
      addressCopy['id'] = addressId;

      final existingIndex = addresses.indexWhere(
        (saved) => saved['id']?.toString() == addressId,
      );
      if (existingIndex >= 0) {
        addresses[existingIndex] = addressCopy;
      } else {
        addresses.add(addressCopy);
      }

      var defaultAddressId = _defaultAddressIdFrom(data, addresses);
      if (makeDefault || defaultAddressId == null) {
        defaultAddressId = addressId;
      }
      _syncLegacyDefaultFlags(addresses, defaultAddressId);
      await customerRef.update({
        'savedAddresses': addresses,
        'defaultAddressId': defaultAddressId,
      });
      return addressCopy;
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER ADDRESS FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to save address. Please try again.',
      );
    }
  }

  Future<void> setDefaultCustomerAddress(String addressId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const FirebaseCustomerProfileException(
        'You must be signed in to select an address.',
      );
    }

    try {
      final customerRef = FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid);
      final snapshot = await customerRef.get();
      if (!snapshot.exists) {
        throw const FirebaseCustomerProfileException(
          'Customer profile could not be found. Please sign in again.',
        );
      }
      final data = snapshot.data() ?? <String, dynamic>{};
      final addresses = _savedAddressesFrom(data);
      if (!addresses.any((address) => address['id']?.toString() == addressId)) {
        throw const FirebaseCustomerProfileException(
          'That saved address is no longer available.',
        );
      }
      _syncLegacyDefaultFlags(addresses, addressId);
      await customerRef.update({
        'savedAddresses': addresses,
        'defaultAddressId': addressId,
      });
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER ADDRESS FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to select address. Please try again.',
      );
    }
  }

  Future<void> deleteCustomerAddress(String addressId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const FirebaseCustomerProfileException(
        'You must be signed in to remove an address.',
      );
    }

    try {
      final customerRef = FirebaseFirestore.instance
          .collection('customers')
          .doc(user.uid);
      final snapshot = await customerRef.get();
      if (!snapshot.exists) {
        throw const FirebaseCustomerProfileException(
          'Customer profile could not be found. Please sign in again.',
        );
      }
      final data = snapshot.data() ?? <String, dynamic>{};
      final addresses = _savedAddressesFrom(data);
      final oldDefaultId = _defaultAddressIdFrom(data, addresses);
      addresses.removeWhere(
        (address) => address['id']?.toString() == addressId,
      );
      final defaultAddressId = oldDefaultId == addressId ? null : oldDefaultId;
      _syncLegacyDefaultFlags(addresses, defaultAddressId);
      await customerRef.update({
        'savedAddresses': addresses,
        'defaultAddressId': defaultAddressId,
      });
    } on FirebaseException catch (exception, stackTrace) {
      debugPrint('CUSTOMER ADDRESS FIRESTORE ERROR');
      debugPrint('Code: ${exception.code}');
      debugPrint('Message: ${exception.message}');
      debugPrintStack(stackTrace: stackTrace);
      throw const FirebaseCustomerProfileException(
        'Unable to remove address. Please try again.',
      );
    }
  }

  static String? normalizeIndianPhoneNumber(String input) {
    final value = input.trim().replaceAll(RegExp(r'[\s()-]'), '');
    if (RegExp(r'^[6-9]\d{9}$').hasMatch(value)) return '+91$value';
    if (RegExp(r'^\+91[6-9]\d{9}$').hasMatch(value)) return value;
    return null;
  }

  void _clearWebVerifier() {}

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

  static void _logFirebaseAuthException(FirebaseAuthException exception) {
    debugPrint('Firebase Auth Error Code: ${exception.code}');
    debugPrint('Firebase Auth Error Message: ${exception.message}');
  }

  static String _messageForCode(String code) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Please enter a valid mobile number.';
      case 'invalid-verification-code':
        return 'Invalid OTP. Please check the code and try again.';
      case 'session-expired':
        return 'Your OTP has expired. Please request a new OTP.';
      case 'too-many-requests':
        return 'Too many requests. Please try again after some time.';
      case 'quota-exceeded':
        return 'SMS quota exceeded. Please try again later.';
      case 'network-request-failed':
        return 'Network error. Please check your connection and try again.';
      case 'operation-not-allowed':
        return 'Phone authentication is not currently available.';
      default:
        return 'Unable to authenticate. Please try again after some time.';
    }
  }
}
