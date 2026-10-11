These checks use newly invented synthetic fixtures and copy the current production implementation into a disposable native test host. They require Xcode and XcodeGen.

Run `python3 Tests/InlineImages/generate-regression-project.py /path/to/external/scratch`, then build and test the generated `Regression` scheme on an available iOS simulator. Generated projects, build products, and test results belong outside this checkout.

The fixtures never connect to a real server or use existing chats or photos.
