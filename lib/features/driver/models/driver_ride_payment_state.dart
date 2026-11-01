/// Payment labels and controls use the server's settled payment, never the
/// passenger's preferred method as evidence that money was received.
class DriverRidePaymentState {
  const DriverRidePaymentState(this.ride);

  final Map<String, Object?> ride;

  bool get completed => ride['paymentCompleted'] == true;
  bool get cashSelected =>
      ride['paymentMethodCode']?.toString().toLowerCase() == 'cash';
  String get selectedMethodName =>
      ride['selectedPaymentMethodNameAr']?.toString().trim() ??
      switch (ride['paymentMethodCode']?.toString().toLowerCase()) {
        'cash' => 'نقداً',
        'wallet' => 'محفظة يمن درايف',
        'floosak' => 'فلوسك',
        'jaib' => 'جيب',
        _ => 'محفظة خارجية',
      };
  String get collectionMessage => completed
      ? paidMessage
      : 'طريقة الراكب: $selectedMethodName. ${pending ? 'الدفع قيد التنفيذ أو التحقق.' : 'لم يتم الدفع بعد.'}';
  bool get pending => !completed && ride['walletPaymentPending'] == true;
  bool get requiredBeforeStart =>
      !completed && ride['paymentRequiredBeforeStart'] == true;
  bool get startBlocked => pending || requiredBeforeStart;

  String get paidMessage {
    final name = ride['paymentMethodNameAr']?.toString().trim();
    if (name != null && name.isNotEmpty) return 'تم الدفع عبر $name';
    return switch (ride['paymentProvider']?.toString().toLowerCase()) {
      'floosak' => 'تم الدفع عبر فلوسك',
      'jaib' => 'تم الدفع عبر جيب',
      'yemendrivewallet' => 'تم الدفع عبر محفظة يمن درايف',
      'cash' => 'تم الدفع نقداً',
      _ => 'تم دفع قيمة الرحلة',
    };
  }

  String? get message => completed
      ? paidMessage
      : pending
          ? 'دفع الراكب قيد التنفيذ أو التحقق؛ انتظر تأكيد النتيجة قبل بدء الرحلة أو التحصيل.'
          : requiredBeforeStart
              ? 'بانتظار دفع الراكب أو اختياره الدفع النقدي قبل بدء الرحلة.'
              : !cashSelected
                  ? collectionMessage
                  : null;
}
