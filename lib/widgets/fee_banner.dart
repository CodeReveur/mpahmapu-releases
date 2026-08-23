import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models.dart';
import '../theme.dart';

/// The daily platform fee, never hidden. Through the evening and night it sits
/// on the map; a paused account shows at any hour, because nothing else the
/// motari does matters until the balance is cleared.
class FeeBanner extends StatelessWidget {
  final Fees fees;
  final bool busy;
  final VoidCallback onPay;

  const FeeBanner({super.key, required this.fees, required this.busy, required this.onPay});

  @override
  Widget build(BuildContext context) {
    final paused = fees.paused;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Brand.black.withValues(alpha: 0.95),
        border: Border.all(color: paused ? const Color(0xFF7F1D1D) : const Color(0xFF7C3A10)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: paused ? Brand.red : Brand.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paused ? t('fees.paused') : t('fees.due'),
                  style: TextStyle(
                    color: paused ? Brand.red : Brand.text,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  fees.dueDays > 1
                      ? t('fees.days',
                          {'amount': rwf(fees.dueAmountRwf), 'days': fees.dueDays})
                      : rwf(fees.dueAmountRwf),
                  style: Brand.micro,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: busy || fees.paymentPending ? null : onPay,
            style: ElevatedButton.styleFrom(
              backgroundColor: fees.paymentPending ? const Color(0xFF1A1A1A) : Brand.orange,
              foregroundColor: fees.paymentPending ? Brand.muted : Colors.black,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            child: Text(
              fees.paymentPending ? t('fees.approve_on_phone') : t('fees.pay_now'),
              style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}
