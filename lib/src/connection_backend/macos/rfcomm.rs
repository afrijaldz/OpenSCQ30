use std::{
    collections::{HashMap, HashSet},
    ffi::{CStr, c_char, c_int, c_void},
    panic::Location,
    ptr::NonNull,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use macaddr::MacAddr6;
use tokio::sync::{mpsc, watch};
use tracing::{debug, debug_span, trace, warn};
use uuid::Uuid;

use crate::{
    api::connection::{self, ConnectionStatus, RfcommBackend, RfcommConnection},
    connection::RfcommServiceSelectionStrategy,
};

// See rfcomm.m for the implementation of these.
pub(super) mod ffi {
    use std::ffi::{c_char, c_int, c_void};

    pub const OK: c_int = 0;
    pub const ERR_DEVICE_NOT_FOUND: c_int = 1;

    pub type DeviceCallback =
        unsafe extern "C" fn(ctx: *mut c_void, name: *const c_char, mac: *const u8);
    pub type ServiceCallback =
        unsafe extern "C" fn(ctx: *mut c_void, uuid: *const u8, channel_id: u8);
    pub type DataCallback = unsafe extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize);
    pub type ClosedCallback = unsafe extern "C" fn(ctx: *mut c_void);

    unsafe extern "C" {
        pub fn scq_bt_connected_devices(callback: DeviceCallback, ctx: *mut c_void);
        pub fn scq_bt_rfcomm_services(
            mac: *const u8,
            callback: ServiceCallback,
            ctx: *mut c_void,
        ) -> c_int;
        pub fn scq_rfcomm_open(
            mac: *const u8,
            channel_id: u8,
            data_callback: DataCallback,
            closed_callback: ClosedCallback,
            ctx: *mut c_void,
            error_out: *mut c_int,
        ) -> *mut c_void;
        pub fn scq_rfcomm_write(handle: *mut c_void, data: *const u8, len: usize) -> c_int;
        pub fn scq_rfcomm_close(handle: *mut c_void);
        pub fn scq_main_run_loop_run();
        pub fn scq_main_run_loop_stop();
    }
}

#[derive(thiserror::Error, Debug)]
#[error("IOBluetooth error code {0}")]
struct IOBluetoothError(c_int);

#[derive(Default)]
pub struct IOBluetoothRfcommBackend;

#[async_trait]
impl RfcommBackend for IOBluetoothRfcommBackend {
    async fn devices(&self) -> connection::Result<HashSet<connection::ConnectionDescriptor>> {
        tokio::task::spawn_blocking(|| {
            let mut descriptors = HashSet::new();

            unsafe extern "C" fn on_device(ctx: *mut c_void, name: *const c_char, mac: *const u8) {
                // SAFETY: ctx is the &mut HashSet passed below, and the callback is only invoked
                // synchronously for the duration of scq_bt_connected_devices.
                let descriptors =
                    unsafe { &mut *(ctx as *mut HashSet<connection::ConnectionDescriptor>) };
                let name = unsafe { CStr::from_ptr(name) }
                    .to_string_lossy()
                    .into_owned();
                let mac_address = unsafe { mac_from_ptr(mac) };
                descriptors.insert(connection::ConnectionDescriptor { name, mac_address });
            }

            unsafe {
                ffi::scq_bt_connected_devices(on_device, &mut descriptors as *mut _ as *mut c_void);
            }
            Ok(descriptors)
        })
        .await
        .unwrap()
    }

    async fn connect(
        &self,
        mac_address: MacAddr6,
        service_selection_strategy: RfcommServiceSelectionStrategy,
    ) -> connection::Result<Arc<dyn RfcommConnection + Send + Sync>> {
        tokio::task::spawn_blocking(
            move || -> connection::Result<Arc<dyn RfcommConnection + Send + Sync>> {
                let span = debug_span!(
                    "RfcommBackend::connect",
                    mac_address = tracing::field::display(mac_address),
                );
                let _span_guard = span.enter();

                debug!("listing RFCOMM services");
                let services = Self::rfcomm_services(mac_address)?;
                debug!("found RFCOMM services: {:?}", services.keys());

                let uuid = match service_selection_strategy {
                    RfcommServiceSelectionStrategy::Constant(uuid) => uuid,
                    RfcommServiceSelectionStrategy::Dynamic(select_service) => {
                        select_service(services.keys().copied().collect())
                    }
                };
                debug!("using RFCOMM service: {uuid:?}");
                let channel_id =
                    services
                        .get(&uuid)
                        .copied()
                        .ok_or(connection::Error::DeviceNotFound {
                            source: None,
                            location: Location::caller(),
                        })?;

                debug!("opening RFCOMM channel {channel_id}");
                let connection = IOBluetoothRfcommConnection::open(mac_address, channel_id)?;
                Ok(Arc::new(connection))
            },
        )
        .await
        .unwrap()
    }
}

impl IOBluetoothRfcommBackend {
    /// Returns a map of service UUID -> RFCOMM channel id
    fn rfcomm_services(mac_address: MacAddr6) -> connection::Result<HashMap<Uuid, u8>> {
        let mut services = HashMap::new();

        unsafe extern "C" fn on_service(ctx: *mut c_void, uuid: *const u8, channel_id: u8) {
            // SAFETY: ctx is the &mut HashMap passed below, and the callback is only invoked
            // synchronously for the duration of scq_bt_rfcomm_services.
            let services = unsafe { &mut *(ctx as *mut HashMap<Uuid, u8>) };
            let bytes: [u8; 16] = unsafe { std::slice::from_raw_parts(uuid, 16) }
                .try_into()
                .unwrap();
            services.insert(Uuid::from_bytes(bytes), channel_id);
        }

        let result = unsafe {
            ffi::scq_bt_rfcomm_services(
                mac_address.as_bytes().as_ptr(),
                on_service,
                &mut services as *mut _ as *mut c_void,
            )
        };
        match result {
            ffi::OK => Ok(services),
            ffi::ERR_DEVICE_NOT_FOUND => Err(connection::Error::DeviceNotFound {
                source: None,
                location: Location::caller(),
            }),
            code => Err(connection::Error::Other {
                source: Box::new(IOBluetoothError(code)),
                location: Location::caller(),
            }),
        }
    }
}

unsafe fn mac_from_ptr(mac: *const u8) -> MacAddr6 {
    let bytes: [u8; 6] = unsafe { std::slice::from_raw_parts(mac, 6) }
        .try_into()
        .unwrap();
    MacAddr6::from(bytes)
}

/// Shared between the connection and the IOBluetooth callbacks. Lives until the channel is closed,
/// at which point no further callbacks can occur.
struct CallbackContext {
    packet_sender: mpsc::Sender<Vec<u8>>,
    connection_status_sender: watch::Sender<ConnectionStatus>,
}

pub struct IOBluetoothRfcommConnection {
    handle: NonNull<c_void>,
    _context: Box<CallbackContext>,
    read_channel: Mutex<Option<mpsc::Receiver<Vec<u8>>>>,
    connection_status_receiver: watch::Receiver<ConnectionStatus>,
}

// SAFETY: the handle is only ever used through the scq_rfcomm_* functions, which are thread safe.
unsafe impl Send for IOBluetoothRfcommConnection {}
unsafe impl Sync for IOBluetoothRfcommConnection {}

impl IOBluetoothRfcommConnection {
    fn open(mac_address: MacAddr6, channel_id: u8) -> connection::Result<Self> {
        let (packet_sender, packet_receiver) = mpsc::channel(100);
        let (connection_status_sender, connection_status_receiver) =
            watch::channel(ConnectionStatus::Connected);
        let context = Box::new(CallbackContext {
            packet_sender,
            connection_status_sender,
        });

        unsafe extern "C" fn on_data(ctx: *mut c_void, data: *const u8, len: usize) {
            let context = unsafe { &*(ctx as *const CallbackContext) };
            let packet = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
            trace!("received packet: {packet:?}");
            // We're on the IOBluetooth thread, so don't block it if the consumer is slow
            if let Err(err) = context.packet_sender.try_send(packet) {
                warn!("dropping inbound packet: {err:?}");
            }
        }

        unsafe extern "C" fn on_closed(ctx: *mut c_void) {
            let context = unsafe { &*(ctx as *const CallbackContext) };
            debug!("RFCOMM channel closed");
            context
                .connection_status_sender
                .send_replace(ConnectionStatus::Disconnected);
        }

        let mut error_code: c_int = ffi::OK;
        let handle = unsafe {
            ffi::scq_rfcomm_open(
                mac_address.as_bytes().as_ptr(),
                channel_id,
                on_data,
                on_closed,
                &*context as *const CallbackContext as *mut c_void,
                &mut error_code,
            )
        };
        let Some(handle) = NonNull::new(handle) else {
            return Err(match error_code {
                ffi::ERR_DEVICE_NOT_FOUND => connection::Error::DeviceNotFound {
                    source: None,
                    location: Location::caller(),
                },
                code => connection::Error::Other {
                    source: Box::new(IOBluetoothError(code)),
                    location: Location::caller(),
                },
            });
        };

        Ok(Self {
            handle,
            _context: context,
            read_channel: Mutex::new(Some(packet_receiver)),
            connection_status_receiver,
        })
    }
}

#[async_trait]
impl RfcommConnection for IOBluetoothRfcommConnection {
    async fn write(&self, data: &[u8]) -> connection::Result<()> {
        let handle = self.handle.as_ptr() as usize;
        let data = data.to_owned();
        tokio::task::spawn_blocking(move || -> connection::Result<()> {
            let result =
                unsafe { ffi::scq_rfcomm_write(handle as *mut c_void, data.as_ptr(), data.len()) };
            if result != ffi::OK {
                return Err(connection::Error::WriteError {
                    source: Some(Box::new(IOBluetoothError(result))),
                    location: Location::caller(),
                });
            }
            trace!("wrote packet: {data:?}");
            Ok(())
        })
        .await
        .unwrap()
    }

    fn read_channel(&self) -> mpsc::Receiver<Vec<u8>> {
        self.read_channel
            .lock()
            .unwrap()
            .take()
            .expect("read_channel may only be called once per IOBluetoothRfcommConnection")
    }

    fn connection_status(&self) -> watch::Receiver<ConnectionStatus> {
        self.connection_status_receiver.clone()
    }
}

impl Drop for IOBluetoothRfcommConnection {
    fn drop(&mut self) {
        // Closing synchronously guarantees no callbacks reference `context` after this returns
        unsafe { ffi::scq_rfcomm_close(self.handle.as_ptr()) };
    }
}
