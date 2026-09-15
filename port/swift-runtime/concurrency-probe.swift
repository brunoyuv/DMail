// Native runtime smoke coverage; this is not Thunderbird source.
private actor Counter {
  private var value = 0
  func increment() { value += 1 }
  func read() -> Int { value }
}

@_cdecl("swift_harmony_concurrency_probe")
public func swiftHarmonyConcurrencyProbe(_ completed: @escaping @convention(c) (Int32) -> Void) {
  Task.detached {
    let counter = Counter()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask { await counter.increment() }
      }
    }
    guard await counter.read() == 100 else { completed(1); return }
    do {
      try await Task.sleep(nanoseconds: 10_000_000)
      let cancelled = Task {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      }
      cancelled.cancel()
      do {
        try await cancelled.value
        completed(2)
      } catch is CancellationError {
        completed(0)
      } catch {
        completed(3)
      }
    } catch {
      completed(4)
    }
  }
}
