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

Below are the steps that should be run beforehand if they are used in a workflow with this step.

- [Git Clone](#todo)
- [Android Test Report](#todo)
- [iOS Test Report](#todo)
- [Android Build](#todo)
- [Android Build UI Test](#todo)
- [iOS Build For Testing](#todo)
- [iOS Build Simulator](#todo)

### Following Steps

There are no subsequent steps advised to be run for this step to work as expected.
