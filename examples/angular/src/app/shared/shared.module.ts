import {ModuleWithProviders, NgModule} from '@angular/core';

import {SharedService} from "./shared.service";

@NgModule({})
export class SharedModule {
  static forRoot(): ModuleWithProviders<SharedModule> {
    return {
      ngModule: SharedModule,
      providers: [SharedService]
    };
  }
}
