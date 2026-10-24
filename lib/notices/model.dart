/// The immutable notice state the host renders.
///
/// Only the [NoticeCenter]'s message handling replaces this state; widgets
/// render it and dispatch typed messages.
part of 'controller.dart';

final class NoticeModel {
  const NoticeModel({this.active = const <Notice>[]});

  /// Active notices in the order they were reported.
  final List<Notice> active;

  NoticeModel copyWith({List<Notice>? active}) =>
      NoticeModel(active: active ?? this.active);
}
