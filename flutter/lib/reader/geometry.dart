part of 'view.dart';

class SurfaceTransform {
  const SurfaceTransform(this.source, this.destination);

  factory SurfaceTransform.create(BoxFit fit, Size input, Size output) {
    final fitted = applyBoxFit(fit, input, output);
    return SurfaceTransform(
      Alignment.center.inscribe(fitted.source, Offset.zero & input),
      Alignment.center.inscribe(fitted.destination, Offset.zero & output),
    );
  }

  final Rect source;
  final Rect destination;

  double get scaleX => destination.width / source.width;
  double get scaleY => destination.height / source.height;

  Offset toSource(Offset point, {bool clamp = false}) {
    final value = Offset(
      source.left + (point.dx - destination.left) / scaleX,
      source.top + (point.dy - destination.top) / scaleY,
    );
    return clamp
        ? Offset(
            value.dx.clamp(source.left, source.right),
            value.dy.clamp(source.top, source.bottom),
          )
        : value;
  }

  Rect toDestinationRect(Rect rect) => Rect.fromLTRB(
    destination.left + (rect.left - source.left) * scaleX,
    destination.top + (rect.top - source.top) * scaleY,
    destination.left + (rect.right - source.left) * scaleX,
    destination.top + (rect.bottom - source.top) * scaleY,
  );

  void apply(Canvas canvas) {
    canvas.clipRect(destination);
    canvas.translate(destination.left, destination.top);
    canvas.scale(scaleX, scaleY);
    canvas.translate(-source.left, -source.top);
  }
}
