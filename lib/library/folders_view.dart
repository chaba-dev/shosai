import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart'
    show LocationException, LocationFailure;
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/google_drive_authorization.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/folders_controller.dart';

class LibraryFoldersDialog extends StatelessWidget {
  const LibraryFoldersDialog({super.key, required this.controller});
  final FoldersController controller;

  /// A folder connection kept from an earlier build on a phone or tablet is
  /// listed only so it can be removed.
  bool _readsFolder(LibraryConnection grant) =>
      controller.supportsFolders ||
      grant.provider != FolderConnectionProvider.providerId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final model = controller.model;
      final l10n = AppLocalizations.of(context);
      final selected =
          model.pending ??
          model.grants.where((grant) => grant.id == model.selected).firstOrNull;
      final startingFolder = switch (selected?.provider) {
        'google-drive' => l10n.locationMyDrive,
        'dropbox' => l10n.locationDropboxAppFolder,
        _ => selected?.label ?? '',
      };
      final directoryLabel = model.choosingDirectory
          ? model.parents.lastOrNull?.name ?? startingFolder
          : selected?.label ?? '';
      return ShadDialog(
        title: Text(selected == null ? l10n.libraryLocations : selected.label),
        description: Text(
          model.pending != null
              ? l10n.locationConfirmSource
              : controller.supportsFolders
              ? l10n.libraryLocationsDescription
              : l10n.libraryLocationsDescriptionMobile,
        ),
        actions: [
          if (model.choosingDirectory)
            ShadButton(
              onPressed: model.busy || model.error != null
                  ? null
                  : () => controller.dispatch(const FoldersDirectorySaved()),
              child: Text(l10n.locationUseFolder),
            ),
          if (model.selected == null && controller.supportsFolders)
            ShadButton.outline(
              height: shosaiShadButtonHeight(context),
              onPressed: model.busy
                  ? null
                  : () => controller.dispatch(const FoldersAddRequested()),
              child: Text(l10n.locationAddFolder),
            ),
          if (model.pending != null)
            ShadButton.outline(
              onPressed: model.saving
                  ? null
                  : () => controller.dispatch(const FoldersCancelRequested()),
              child: Text(l10n.locationCancel),
            )
          else
            ShadButton(
              height: shosaiShadButtonHeight(context),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.locationClose),
            ),
        ],
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: 520,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (model.busy)
                  LinearProgressIndicator(semanticsLabel: l10n.locationLoading),
                if (model.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(switch (model.error) {
                      GoogleDriveRegistrationRequired() =>
                        l10n.locationGoogleDriveRegistrationRequired,
                      GoogleDriveSetupException(
                        stage: GoogleDriveSetupStage.tokenExchange,
                        oauthError: final error,
                      ) =>
                        l10n.locationGoogleDriveTokenRejected(error!),
                      GoogleDriveSetupException(
                        stage: GoogleDriveSetupStage.permissions,
                      ) =>
                        l10n.locationGoogleDrivePermissionsIncomplete,
                      GoogleDriveSetupException(
                        stage: GoogleDriveSetupStage.credentialStorage,
                      ) =>
                        l10n.locationGoogleDriveCredentialStorageFailed,
                      LocationException(failure: LocationFailure.offline) =>
                        l10n.locationOffline,
                      LocationException(failure: LocationFailure.revoked) =>
                        l10n.locationRevoked,
                      LocationException(failure: LocationFailure.missing) =>
                        l10n.locationMissing,
                      _ => l10n.locationFailed,
                    }),
                  ),
                if (selected != null)
                  Row(
                    children: [
                      IconButton(
                        tooltip: l10n.locationBack,
                        onPressed:
                            model.saving ||
                                (model.busy && model.pending == null)
                            ? null
                            : () => controller.dispatch(
                                const FoldersBackRequested(),
                              ),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Text(
                          directoryLabel,
                          style: shosaiInterfaceStyleForText(
                            ShadTheme.of(context).textTheme.p,
                            directoryLabel,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      if (selected == null) ...[
                        if (controller.supportsDropbox)
                          ListTile(
                            leading: const Icon(Icons.cloud_outlined),
                            title: Text(l10n.dropboxConnect),
                            enabled: !model.busy,
                            onTap: model.busy
                                ? null
                                : () => controller.dispatch(
                                    const FoldersAddDropboxRequested(),
                                  ),
                          ),
                        if (controller.canAddGoogleDrive)
                          ListTile(
                            leading: const Icon(Icons.cloud_outlined),
                            title: Text(l10n.locationAddGoogleDrive),
                            enabled: !model.busy,
                            onTap: model.busy
                                ? null
                                : () => controller.dispatch(
                                    const FoldersAddGoogleDriveRequested(),
                                  ),
                          ),
                        if (model.grants.isEmpty && !model.busy)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              controller.supportsFolders
                                  ? l10n.locationNoFolders
                                  : l10n.locationNoFoldersMobile,
                            ),
                          ),
                        for (final grant in model.grants)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(grant.label),
                            subtitle: Text(
                              _readsFolder(grant)
                                  ? '${l10n.locationSourceFolder}: ${grant.directoryLabel ?? grant.label}'
                                  : l10n.locationFolderNotRead,
                            ),
                            onTap: model.busy || !_readsFolder(grant)
                                ? null
                                : () => controller.dispatch(
                                    FoldersSelected(grant.id),
                                  ),
                            trailing: IconButton(
                              tooltip: l10n.locationRemove,
                              onPressed: model.busy
                                  ? null
                                  : () => controller.dispatch(
                                      FoldersRemoveRequested(grant.id),
                                    ),
                              icon: const Icon(Icons.link_off),
                            ),
                          ),
                      ] else if (!model.choosingDirectory) ...[
                        ListTile(
                          title: Text(l10n.locationSourceFolder),
                          subtitle: Text(
                            selected.directoryLabel ?? selected.label,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            controller.canReconnect(selected)
                                ? l10n.locationReconnectDescription
                                : l10n.locationSourceDescription,
                          ),
                        ),
                        if (controller.canReconnect(selected))
                          ShadButton.outline(
                            height: shosaiShadButtonHeight(context),
                            enabled: !model.busy,
                            onPressed: model.busy
                                ? null
                                : () => controller.dispatch(
                                    const FoldersReconnectRequested(),
                                  ),
                            child: Text(l10n.locationReconnect),
                          ),
                        ShadButton.outline(
                          enabled: !model.busy,
                          onPressed: model.busy
                              ? null
                              : () => controller.dispatch(
                                  const FoldersChooseDirectoryRequested(),
                                ),
                          child: Text(l10n.locationChooseFolder),
                        ),
                        ShadButton.ghost(
                          enabled: !model.busy,
                          onPressed: model.busy
                              ? null
                              : () => controller.dispatch(
                                  FoldersRemoveRequested(selected.id),
                                ),
                          child: Text(l10n.locationRemove),
                        ),
                      ] else ...[
                        if (model.error != null)
                          ShadButton.outline(
                            onPressed: model.busy
                                ? null
                                : () => controller.dispatch(
                                    const FoldersRetryRequested(),
                                  ),
                            child: Text(l10n.libraryRetry),
                          ),
                        for (final entry in model.entries.where(
                          (entry) => entry.isDirectory,
                        ))
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(entry.name),
                            onTap: model.busy
                                ? null
                                : () => controller.dispatch(
                                    FoldersEntryChosen(entry),
                                  ),
                          ),
                        if (model.nextCursor != null)
                          ShadButton.outline(
                            onPressed: model.busy
                                ? null
                                : () => controller.dispatch(
                                    const FoldersNextRequested(),
                                  ),
                            child: Text(l10n.locationNextPage),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
