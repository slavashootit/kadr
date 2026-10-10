import SwiftUI

/// Drop-in for `@State` that avoids the SwiftUI `State` macro: newer SDKs implement `@State` as a macro whose
/// plugin ships only with full Xcode, so builds with Command Line Tools alone fail.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
