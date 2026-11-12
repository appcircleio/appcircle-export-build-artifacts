# Appcircle _Export Build Artifacts_ component

Exports the specified build artifacts from the build agent to the Appcircle dashboard. The exported files will be available for download from the artifacts section of the completed build.

## Input Variables

### Required

- `AC_UPLOAD_DIR`: If a folder path is specified, the files in this folder will be exported as artifacts. If a file path is specified, that file will be exported as an artifact. Uploading files with a 0 byte size in the specified path will be skipped.

### Optional

- `AC_DISABLE_UPLOAD_ON_FAIL`: Delete build artifacts if any of your workflow steps failed. Only build logs will be uploaded.

## Relationship

Below workflow steps are related with this step and should be used as recommended.

### Required Steps

There is no required step that needs to be run beforehand for this step to work as expected.

### Preceding Steps

Below are the steps that should be run beforehand if they are used in the workflow with this step.
- [Git Clone](https://github.com/appcircleio/appcircle-git-clone-component.git)
- [Test Report](https://github.com/appcircleio/appcircle-test-report-component.git)
- [Android Build](https://github.com/appcircleio/appcircle-android-build-component.git)
- [Android Build UI Test](https://github.com/appcircleio/appcircle-android-build-ui-test-component.git)
- [iOS Build For Testing](https://github.com/appcircleio/appcircle-ios-build-for-testing.git)
- [iOS Build Simulator](https://github.com/appcircleio/appcircle-ios-build-simulator.git)

### Following Steps

There are no subsequent steps advised to be run for this step to work as expected.

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

The subprocess tests run the real `main.rb` inside a sandbox: HTTP requests are answered locally, `zip` and `sleep` are recorded instead of executed, and file operations outside a per-test temp directory are refused. A coverage report is printed at the end of each run.
