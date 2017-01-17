//
//  GeocoderRequest.swift
//  SwiftLocation
//
//  Created by Daniele Margutti on 17/01/2017.
//  Copyright © 2017 Daniele Margutti. All rights reserved.
//

import Foundation
import MapKit
import CoreLocation


/// Reverse Geocoder Request callback
///
/// - onReversed: success callback
/// - onErrorOccurred: failure callback
public enum GeocoderCallback {
	public typealias onSuccess = ((_ placemarks: [CLPlacemark]) -> (Void))
	public typealias onError = ((_ error: Error) -> (Void))
	
	case onReversed(_: Context, _: onSuccess)
	case onErrorOccurred(_: Context, _: onError)
}


/// Type of geocoder request
///
/// - location: geocode of a `CLLocation` instance
/// - address: geocode of a `String` address (ex. `"1, Infinite Loop, Cupertino (CA)"`)
/// - abDictionary: geocode an Address Book dictionary
public enum GeocoderSource {
	case location(_: CLLocation)
	case address(_: String, _: CLRegion?)
	case abDictionary(_: [AnyHashable : Any])
}

public class GeocoderRequest: Request {
	
	/// Cached placemark founds
	private var foundPlacemarks: [CLPlacemark]?
	
	/// Last received error
	private(set) var lastError: Error?
	
	/// Instance of geocoder
	private var geocoder: CLGeocoder? = nil
	
	/// Unique identifier of the request
	private var identifier = NSUUID().uuidString
	
	/// Type of geocoding
	private(set) var source: GeocoderSource
	
	/// Callback to call when request's state did change
	public var onStateChange: ((_ old: RequestState, _ new: RequestState) -> (Void))?
	
	/// Callbacks registered
	public var registeredCallbacks: [GeocoderCallback] = []
	
	/// Remove queued request if an error has occurred. By default is `false`.
	public var cancelOnError: Bool = false
	
	/// This represent the current state of the Request
	internal var _previousState: RequestState = .idle
	internal(set) var _state: RequestState = .idle {
		didSet {
			if _previousState != _state {
				onStateChange?(_previousState,_state)
				_previousState = _state
			}
		}
	}
	public var state: RequestState {
		get {
			return self._state
		}
	}
	
	/// Set a valid interval to enable a timer. Timeout starts automatically
	private var timeoutTimer: Timer?
	public var timeout: TimeInterval? = nil {
		didSet {
			timeoutTimer?.invalidate()
			timeoutTimer = nil
			guard let interval = self.timeout else {
				return
			}
			self.timeoutTimer = Timer.scheduledTimer(timeInterval: interval,
			                                         target: self,
			                                         selector: #selector(timeoutTimerFired),
			                                         userInfo: nil,
			                                         repeats: false)
		}
	}
	
	@objc func timeoutTimerFired() {
		self.dispatch(error: LocationError.timeout)
	}
	
	/// Initialize a new geocoder request for an address string
	///
	/// - Parameters:
	///   - address: source string to geocode
	///   - region: A geographical region to use as a hint when looking up the specified address.
	///				Specifying a region lets you prioritize the returned set of results to locations that are close to some
	///				specific geographical area, which is typically the user’s current location.
	///   - success: handler to call on success
	///   - failure: handler to call on failure
	public init(address: String, region: CLRegion? = nil,
	            _ success: @escaping GeocoderCallback.onSuccess, _ failure: @escaping GeocoderCallback.onError) {
		self.source = .address(address, region)
		self.add(callback: GeocoderCallback.onReversed(.main, success))
		self.add(callback: GeocoderCallback.onErrorOccurred(.main, failure))
	}
	
	/// Initialize a new reverse geocoder request for a `CLLocation` instance.
	///
	/// - Parameters:
	///   - location: location to check
	///   - success: handler to call on success
	///   - failure: handler to call on failure
	public init(location: CLLocation,
	            _ success: @escaping GeocoderCallback.onSuccess, _ failure: @escaping GeocoderCallback.onError) {
		self.source = .location(location)
		self.add(callback: GeocoderCallback.onReversed(.main, success))
		self.add(callback: GeocoderCallback.onErrorOccurred(.main, failure))
	}
	
	/// Initialize a new reverse geocoder request for an Address Book dictionary containing information about the address to look up.
	///
	/// - Parameters:
	///   - abDictionary: address book dictionary containing information about the address to look up
	///   - success: handler to call on success
	///   - failure: handler to call on failure
	public init(abDictionary: [AnyHashable : Any],
	            _ success: @escaping GeocoderCallback.onSuccess, _ failure: @escaping GeocoderCallback.onError) {
		self.source = .abDictionary(abDictionary)
		self.add(callback: GeocoderCallback.onReversed(.main, success))
		self.add(callback: GeocoderCallback.onErrorOccurred(.main, failure))
	}
	
	/// Register a new callback to call on `success` or `failure`
	///
	/// - Parameter callback: callback to append into registered callback list
	public func add(callback: GeocoderCallback?) {
		guard let callback = callback else { return }
		self.registeredCallbacks.append(callback)
	}
	
	/// Implementation of the hash function
	public var hashValue: Int {
		return identifier.hash
	}
	
	/// `true` if request is on location queue
	internal var isInQueue: Bool {
		return Location.isQueued(self) == true
	}
	
	/// Resume a paused request or start it
	@discardableResult
	public func resume() {
		Location.start(self)
	}
	
	/// Pause a running request.
	///
	/// - Returns: `true` if request is paused, `false` otherwise.
	@discardableResult
	public func pause() {
		Location.pause(self)
	}
	
	/// Cancel a running request and remove it from queue.
	public func cancel() {
		Location.cancel(self)
	}
	
	public func onResume() {
		if let foundPlacemarks = self.foundPlacemarks {
			self.dispatch(placemarks: foundPlacemarks)
			return
		}
		
		self.lastError = nil
		geocoder = CLGeocoder()
		
		// Geocoder completion handler
		let handler: CLGeocodeCompletionHandler = { placemarks, error in
			guard let foundPlacemarks = placemarks else { // no found placemark
				guard let error = error else { // no error -> no data
					self.lastError = LocationError.noData
					self.dispatch(error: self.lastError!)
					return
				}
				// a valid error has occurred
				self.lastError = error
				self.dispatch(error: self.lastError!)
				return
			}
			// placemark(s) found
			self.dispatch(placemarks: foundPlacemarks)
		}
		
		switch self.source {
		case .location(let location): // CLLocation Reverse Geocoding
			geocoder!.reverseGeocodeLocation(location, completionHandler: handler)
		case .address(let address, let hintRegion): // Address String Reverse Geocoding
			geocoder!.geocodeAddressString(address, in: hintRegion, completionHandler: handler)
		case .abDictionary(let abDict): // Address Book Dictionary Reverse Geocoding
			geocoder!.geocodeAddressDictionary(abDict, completionHandler: handler)
		}
	}
	
	
	/// Dispatch error to any failure registered callback
	///
	/// - Parameter error: error to dispatch
	private func dispatch(error: Error) {
		self.registeredCallbacks.forEach {
			if case .onErrorOccurred(let context, let handler) = $0 {
				context.queue.async { handler(error) }
			}
		}
	}
	
	/// Dispatch placemarks to any success registered callback
	///
	/// - Parameter placemarks: placemarks to dispatch
	private func dispatch(placemarks: [CLPlacemark]) {
		self.registeredCallbacks.forEach {
			if case .onReversed(let context, let handler) = $0 {
				context.queue.async { handler(placemarks) }
			}
		}
	}
	
	public func onPause() {
		// Cancel geocoding request
		geocoder?.cancelGeocode()
	}
	
	public func onCancel() {
		
	}
	
	/// Returns a Boolean value indicating whether two values are equal.
	///
	/// Equality is the inverse of inequality. For any values `a` and `b`,
	/// `a == b` implies that `a != b` is `false`.
	///
	/// - Parameters:
	///   - lhs: A value to compare.
	///   - rhs: Another value to compare.
	public static func ==(lhs: GeocoderRequest, rhs: GeocoderRequest) -> Bool {
		return lhs.hashValue == rhs.hashValue
	}
	
}
