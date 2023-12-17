# Appcircle Export Build Artifacts

Exports the specified build artifacts from the build agent to the Appcircle dashboard. The exported files will be available for download from the artifacts section of the completed build.

## Required Inputs

- `AC_UPLOAD_DIR`: If a folder path is specified, the files in this folder will be exported as artifacts. If a file path is specified, that file will be exported as an artifact. Uploading files with a 0 byte size in the specified path will be skipped.

## Optional Inputs

- `AC_DISABLE_UPLOAD_ON_FAIL`: Delete build artifacts if any of your workflow steps failed. Only build logs will be uploaded.

## Output Variables

There are no output variables available.
