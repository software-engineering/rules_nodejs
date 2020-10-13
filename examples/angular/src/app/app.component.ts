import {Component} from '@angular/core';
import {SharedService} from "./shared/shared.service";

@Component({selector: 'app-component', templateUrl: 'app.component.html'})
export class AppComponent {
    constructor(private sharedService: SharedService) {
        sharedService.data = 'app-component';
    }
}
