@Entry
@Component
struct TestLoadingFixture {
  build() {
    Column() { Text('Preparing mail preview') }
      .width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor($r('sys.color.background_primary'))
  }
}
