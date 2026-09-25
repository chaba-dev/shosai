import 'notice.dart';

/// The outcome a controller is reporting to the notice center.
///
/// These are the product outcomes decision 13 distinguishes, not widget
/// states: a feature may report a load failure as a notice or keep its own
/// inline persistent surface, but the policy below fixes what a notice for
/// that outcome must look like.
enum NoticeOutcome {
  /// A completed operation with nothing left for the user to act on.
  success,

  /// An import that imported some books and failed or warned about others.
  partialImport,

  /// A failed import, save, removal or other mutation.
  failure,

  /// A referenced book's file is gone.
  missingFile,

  /// The platform denied access to a selected document or location.
  permissionDenied,

  /// Cleanup or deletion that the application still owes the user.
  deletionDebt,

  /// The user cancelled the operation.
  cancellation,

  /// An error the current dialog can correct in place.
  correctableDialogError,
}

/// The presentation a notice for an outcome must use.
final class NoticeDisposition {
  const NoticeDisposition({required this.kind, required this.lifetime});

  final NoticeKind kind;
  final NoticeLifetime lifetime;
}

/// Package 2D's feedback policy, shared by every reporter.
///
/// Decision 13: successful imports, settings saves and copy actions use brief
/// feedback; failed or partial imports, failed saves, missing files,
/// permission problems and cleanup or deletion debt remain visible with details
/// and applicable recovery actions; cancellation is neutral; a correctable
/// error stays inline in the dialog that can correct it.
///
/// [dispositionFor] returns null for the two outcomes that must not become a
/// notice at all: cancellation and a correctable dialog error. A null result is
/// a policy decision, not a missing case: reporting them would either colour a
/// neutral action as a failure or present a dialog error outside the dialog.
abstract final class NoticePolicy {
  /// How long a brief notice stays in the model.
  static const Duration briefDuration = Duration(seconds: 4);

  /// Identity of the unresolved condition behind a library import.
  static const String libraryImportKey = 'library.import';

  /// Identity of the unresolved condition behind a settings save.
  static const String librarySettingsKey = 'library.settings';

  /// Identity of the unresolved condition behind a book removal.
  static const String libraryRemovalKey = 'library.removal';

  static NoticeDisposition? dispositionFor(NoticeOutcome outcome) =>
      switch (outcome) {
        NoticeOutcome.success => const NoticeDisposition(
          kind: NoticeKind.success,
          lifetime: NoticeLifetime.brief,
        ),
        NoticeOutcome.partialImport ||
        NoticeOutcome.failure ||
        NoticeOutcome.missingFile ||
        NoticeOutcome.permissionDenied => const NoticeDisposition(
          kind: NoticeKind.failure,
          lifetime: NoticeLifetime.persistent,
        ),
        NoticeOutcome.deletionDebt => const NoticeDisposition(
          kind: NoticeKind.warning,
          lifetime: NoticeLifetime.persistent,
        ),
        NoticeOutcome.cancellation ||
        NoticeOutcome.correctableDialogError => null,
      };
}
