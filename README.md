# Appcircle _Export Build Artifacts_ component

Exports the specified build artifacts from the build agent to the Appcircle dashboard. The exported files will be available for download from the artifacts section of the completed build.

## Required Input Variables

- `AC_UPLOAD_DIR`: If a folder path is specified, the files in this folder will be exported as artifacts. If a file path is specified, that file will be exported as an artifact. Uploading files with a 0 byte size in the specified path will be skipped.

## Optional Inputs Variables

- `AC_DISABLE_UPLOAD_ON_FAIL`: Delete build artifacts if any of your workflow steps failed. Only build logs will be uploaded.

## Required Steps

- There is no required step that needs to be run afterward for this step to work as expected.

## Preceding Steps

-  Git Clone
-  Android Test Report
-  Ios Test Report
-  Android Build
-  Android Build Ui Test
-  Ios Build For Testing
-  Ios Build Simulator

## Following Steps

- There are no subsequent steps advised to be run for this step to work as expected.
