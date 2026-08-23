import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models.dart';
import '../theme.dart';

/// The dispatch offer, held by this motari alone until the countdown ends.
/// It is deliberately loud: on a moving bike it has to be answered at a glance.
class OfferCard extends StatelessWidget {
  final Offer offer;
  final int secondsLeft;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onPass;

  const OfferCard({
    super.key,
    required this.offer,
    required this.secondsLeft,
    required this.busy,
    required this.onAccept,
    required this.onPass,
  });

  @override
  Widget build(BuildContext context) {
    final urgent = secondsLeft <= 10;
    final total = secondsLeft > offer.expiresInSeconds ? secondsLeft : offer.expiresInSeconds;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Brand.black.withValues(alpha: 0.95),
        border: Border.all(color: Brand.orange),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (offer.isCourier) ...[
                const Icon(Icons.inventory_2, size: 12, color: Brand.orange),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  offer.isCourier ? t('offer.parcel') : t('offer.ride'),
                  style: const TextStyle(
                    color: Brand.orange,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Text(
                '${secondsLeft}s',
                style: TextStyle(
                  color: urgent ? Brand.red : Brand.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : secondsLeft / total,
              minHeight: 3,
              backgroundColor: const Color(0xFF1A1A1A),
              valueColor: AlwaysStoppedAnimation(urgent ? Brand.red : Brand.orange),
            ),
          ),
          const SizedBox(height: 9),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: offer.passengerName,
                style: const TextStyle(color: Brand.text, fontWeight: FontWeight.w800, fontSize: 12),
              ),
              TextSpan(
                text: '  ${t('offer.away', {'distance': km(offer.distanceToPickupM)})}',
                style: const TextStyle(color: Brand.muted, fontSize: 11.5),
              ),
            ]),
          ),
          if (offer.parcelNote != null && offer.parcelNote!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              offer.parcelNote!,
              style: const TextStyle(color: Brand.orange, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 4),
          _line(Brand.orange, offer.pickupName ?? t('offer.pinned_pickup')),
          _line(Brand.green, offer.destName ?? t('offer.open_ride')),
          if (offer.destName != null && offer.destLat == null)
            Padding(
              padding: const EdgeInsets.only(left: 13, top: 1),
              child: Text(t('offer.not_on_map'), style: Brand.micro),
            ),
          const SizedBox(height: 4),
          Text(
            offer.offeredFareRwf != null
                ? '${rwf(offer.offeredFareRwf)} · ${t('offer.their_price')}'
                : offer.quotedFareRwf != null
                    ? rwf(offer.quotedFareRwf)
                    : t('offer.meter'),
            style: const TextStyle(color: Brand.orange, fontSize: 12.5, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: PrimaryButton(label: t('offer.accept'), onPressed: busy ? null : onAccept),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: busy ? null : onPass,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Brand.muted,
                    side: const BorderSide(color: Color(0xFF2A2A2A)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    t('offer.pass'),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _line(Color dot, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 6),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
            ),
            Expanded(
              child: Text(text, style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
            ),
          ],
        ),
      );
}
