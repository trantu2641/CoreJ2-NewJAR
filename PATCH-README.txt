CoreJ2-NewJAR iOS 16.4 JAR Import Fix

Replace the matching files in your repository with the files in this ZIP, keeping the paths.
Files included:
- JavaOne/Features/Library/Services/FileImportService.swift
- JavaOne/Features/Library/Services/ImportService.swift
- JavaOne/Features/Library/Views/LibraryView.swift
- JavaOne.xcodeproj/project.pbxproj
- .github/workflows/ios-build.yml

What this changes:
- Uses NavigationLink(isActive:) instead of navigationDestination(item:), compatible with iOS 16.
- Enables JAR import using a security-scoped URL while reading the file, then writes Data into app storage.
- Validates that the selected file is a ZIP/JAR archive and shows actionable import errors.
- Sets project deployment targets from iOS 17.0 to iOS 16.4 (including test targets).
- Keeps the JSON repository / app dependency files already present on the GitHub main branch unchanged.

Note: this is a source patch ZIP, not a compiled IPA. A build on GitHub Actions is required to verify compile/runtime behavior.
