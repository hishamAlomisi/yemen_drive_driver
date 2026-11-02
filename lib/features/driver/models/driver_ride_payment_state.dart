import 'package:get/get.dart';

/// Payment labels and controls use the server's settled payment, never the
/// passenger's preferred method as evidence that money was received.
class DriverRidePaymentState {
  const DriverRidePaymentState(this.ride);

  final Map<String, Object?> ride;
  bool get _english => Get.locale?.languageCode == 'en';
  String _t(String ar, String en) => _english ? en : ar;

  bool get completed => ride['paymentCompleted'] == true;
  bool get cashSelected =>
      ride['paymentMethodCode']?.toString().toLowerCase() == 'cash';
  String get selectedMethodName =>
      ride[_english
              ? 'selectedPaymentMethodNameEn'
              : 'selectedPaymentMethodNameAr']
          ?.toString()
          .trim() ??
      switch (ride['paymentMethodCode']?.toString().toLowerCase()) {
        'cash' => _t('نقداً', 'Cash'),
        'wallet' => _t('محفظة يمن درايف', 'Yemen Drive wallet'),
        'floosak' => _t('فلوسك', 'Floosak'),
        'jaib' => _t('جيب', 'Jaib'),
        _ => _t('محفظة خارجية', 'External wallet'),
      };
  String get collectionMessage => completed
      ? paidMessage
      : '${_t('سيتم الدفع عبر', 'Payment will be made via')} $selectedMethodName. ${pending ? _t('الدفع قيد التنفيذ أو التحقق.', 'Payment is being processed or verified.') : _t('لم يتم الدفع بعد.', 'Payment is incomplete.')}';
  bool get pending => !completed && ride['walletPaymentPending'] == true;
  bool get requiredBeforeStart =>
      !completed && ride['paymentRequiredBeforeStart'] == true;
  bool get startBlocked => pending || requiredBeforeStart;

  String get paidMessage {
    final name = ride[_english ? 'paymentMethodNameEn' : 'paymentMethodNameAr']
        ?.toString()
        .trim();
    if (name != null && name.isNotEmpty)
      return _t('تم الدفع عبر $name', 'Paid via $name');
    return switch (ride['paymentProvider']?.toString().toLowerCase()) {
      'floosak' => _t('تم الدفع عبر فلوسك', 'Paid via Floosak'),
      'jaib' => _t('تم الدفع عبر جيب', 'Paid via Jaib'),
      'yemendrivewallet' =>
        _t('تم الدفع عبر محفظة يمن درايف', 'Paid via Yemen Drive wallet'),
      'cash' => _t('تم الدفع نقداً', 'Paid in cash'),
      _ => _t('تم دفع قيمة الرحلة', 'Ride payment completed'),
    };
  }

  String? get message => completed
      ? paidMessage
      : pending
          ? _t(
              'دفع الراكب قيد التنفيذ أو التحقق؛ انتظر تأكيد النتيجة قبل بدء الرحلة أو التحصيل.',
              'The original payment is unresolved; verify it before starting or collecting another payment.')
          : requiredBeforeStart
              ? _t('بانتظار دفع الراكب أو اختياره الدفع النقدي قبل بدء الرحلة.',
                  'Waiting for the rider to pay or choose cash before starting.')
              : !cashSelected
                  ? collectionMessage
                  : null;
}
