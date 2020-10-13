import {Injectable} from '@angular/core';

@Injectable({
  providedIn: "root"
})
export class SharedService {
  private _data: string;

  public get data(): string {
    return this._data;
  }

  public set data(data: string ) {
    this._data = data;
  }
}
