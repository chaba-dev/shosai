import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart'
    show LocationException, LocationFailure;
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/folders_controller.dart';

class LibraryFoldersDialog extends StatelessWidget {
  const LibraryFoldersDialog({super.key, required this.controller});
  final FoldersController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final model = controller.model;
      final l10n = AppLocalizations.of(context);
      final selected = model.grants
          .where((grant) => grant.id == model.selected)
          .firstOrNull;
      return ShadDialog(
        title: Text(selected == null ? l10n.libraryLocations : selected.label),
        description: Text(l10n.libraryLocationsDescription),
        actions: [
          if (model.choosingDirectory)
            ShadButton(
              onPressed: model.busy || model.error != null
                  ? null
                  : () => controller.dispatch(const FoldersDirectorySaved()),
              child: Text(l10n.locationUseFolder),
            ),
          if (model.selected == null)
            ShadButton.outline(
              height: shosaiShadButtonHeight(context),
              onPressed: model.busy
                  ? null
                  : () => controller.dispatch(const FoldersAddRequested()),
              child: Text(l10n.locationAddFolder),
            ),
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
                        onPressed: model.busy
                            ? null
                            : () => controller.dispatch(
                                const FoldersBackRequested(),
                              ),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Expanded(
                        child: Text(
                          model.parents.lastOrNull?.name ?? selected.label,
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
                        if (model.grants.isEmpty && !model.busy)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(l10n.locationNoFolders),
                          ),
                        for (final grant in model.grants)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(grant.label),
                            subtitle: Text(
                              '${l10n.locationSourceFolder}: ${grant.directoryLabel ?? grant.label}',
                            ),
                            onTap: model.busy
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
                          child: Text(l10n.locationSourceDescription),
                        ),
                        ShadButton.outline(
                          onPressed: model.busy
                              ? null
                              : () => controller.dispatch(
                                  const FoldersChooseDirectoryRequested(),
                                ),
                          child: Text(l10n.locationChooseFolder),
                        ),
                        ShadButton.ghost(
                          onPressed: model.busy
                              ? null
                              : () => controller.dispatch(
                                  FoldersRemoveRequested(selected.id),
                                ),
                          child: Text(l10n.locationRemove),
                        ),
                      ] else ...[
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
