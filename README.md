# tree_edit

A tree editor. I think it's going to become a roam-like? And then a distributed typed data browser.

## building

Currently flutter is the only dependency, so I wont recommend that you install nix just for us, but you might need to in the future.

If you do have nix: run `nix develop`, open vscode, install the flutter extension in vscode, then the "debug" play build thing should appear, flutter build options should be present in the vscode command search.

Otherwise: [install flutter](https://docs.flutter.dev/get-started/install). Run `flutter doctor` to generate the missing files. Run `flutter run`. You may have to specify your platform using `flutter run -d <linux/macos/windows/whatever>`.