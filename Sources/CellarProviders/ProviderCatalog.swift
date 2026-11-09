import CellarCore
import Foundation

public enum ProviderCatalog {
    public static func makeAll(locator: BinaryLocator, runner: ProcessCommandRunner) -> [any PackageProvider] {
        [
            HomebrewProvider(locator: locator, runner: runner),
            NpmProvider(locator: locator, runner: runner),
            PnpmProvider(locator: locator, runner: runner),
            BunProvider(locator: locator, runner: runner),
        ]
    }
}
