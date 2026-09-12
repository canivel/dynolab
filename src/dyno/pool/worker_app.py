"""Small Windows desktop companion. No web server or public RPC listener."""
import json
import queue
import socket
from pathlib import Path
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from .worker import Worker, bundled_binary, gpu_inventory


class WorkerApp:
    def __init__(self, root):
        self.root = root
        self.worker = Worker()
        self.busy = False
        self.closing = False
        self.gpus = []
        self.events = queue.Queue()
        self.pair_server = self.advertisement = None
        self.discovery_status = tk.StringVar(value='Enable discovery once, then find this worker from your coordinator.')
        self.selected_network = ''
        self.network_choice = tk.StringVar()
        root.title('Dyno Lab Worker · experimental')
        root.geometry('860x700')
        root.minsize(730, 600)
        frame = ttk.Frame(root, padding=20)
        frame.pack(fill='both', expand=True)
        ttk.Label(frame, text='Dyno Lab Worker', font=('Segoe UI', 23, 'bold')).pack(anchor='w')
        ttk.Label(frame, text='Share an NVIDIA GPU with Dyno on your local network.').pack(anchor='w', pady=(2, 14))
        self.status = tk.StringVar(value='Stopped')
        ttk.Label(frame, textvariable=self.status, font=('Segoe UI', 13, 'bold')).pack(anchor='w')
        self.metrics = tk.StringVar(value='Checking NVIDIA driver…')
        ttk.Label(frame, textvariable=self.metrics, wraplength=790).pack(anchor='w', pady=8)
        controls = ttk.Frame(frame)
        controls.pack(fill='x', pady=8)
        self.device = tk.StringVar(value='CUDA0')
        self.devices = ttk.Combobox(controls, textvariable=self.device, values=['CUDA0'], width=12, state='readonly')
        self.devices.pack(side='left', padx=(0, 12))
        self.start_button = ttk.Button(controls, text='Start worker', command=self.start)
        self.start_button.pack(side='left')
        self.stop_button = ttk.Button(controls, text='Stop worker', command=self.stop)
        self.stop_button.pack(side='left', padx=8)
        ttk.Button(controls, text='Save diagnostics…', command=self.export).pack(side='right')
        ttk.Label(frame, text='Experimental preview · GPU traffic uses an authenticated pool connection.').pack(anchor='w')
        ttk.Label(frame, text='Stop or quit interrupts active pool requests. GPU metrics cover the whole GPU, including other apps.',
                  wraplength=790).pack(anchor='w', pady=(4, 12))
        tabs = ttk.Notebook(frame)
        tabs.pack(fill='both', expand=True)
        setup = ttk.Frame(tabs, padding=12)
        tabs.add(setup, text='Connect to your pool')
        ttk.Label(setup, text='Find this worker automatically', font=('Segoe UI', 12, 'bold')).pack(anchor='w')
        ttk.Label(setup, text='Enable LAN discovery, open Nearby workers on your coordinator, and compare the code '
                  'on both screens. Windows asks for approval when configuring the connection.', wraplength=760).pack(anchor='w', pady=8)
        ttk.Label(setup, textvariable=self.discovery_status, wraplength=760).pack(anchor='w', pady=8)
        ttk.Label(setup, text='Local network (Private connections only)').pack(anchor='w')
        self.networks = ttk.Combobox(setup, textvariable=self.network_choice, state='readonly', width=35)
        self.networks.pack(anchor='w', pady=4)
        self.networks.bind('<<ComboboxSelected>>', lambda event: setattr(self, 'selected_network', self.network_choice.get()))
        ttk.Button(setup, text='Enable LAN discovery…', command=self.enable_discovery).pack(anchor='w', pady=4)
        ttk.Button(setup, text='Open pairing for 5 minutes', command=lambda: self.background(self.start_discovery)).pack(anchor='w', pady=4)
        ttk.Button(setup, text='Stop discovery', command=lambda: self.background(self.stop_discovery)).pack(anchor='w', pady=4)
        setup = ttk.Frame(tabs, padding=12)
        tabs.add(setup, text='Manual setup')
        log_frame = ttk.Frame(tabs, padding=8)
        tabs.add(log_frame, text='Runtime log')
        ttk.Label(setup, text='One-time connection setup', font=('Segoe UI', 12, 'bold')).pack(anchor='w')
        ttk.Label(setup, text='Paste the coordinator’s LAN IPv4 address and SSH public key. Windows will request administrator approval. '
                  'Setup enables OpenSSH for this coordinator on Private networks only. It does not open the GPU port.',
                  wraplength=760).pack(anchor='w', pady=8)
        self.mac_ip = tk.StringVar()
        ttk.Label(setup, text='Coordinator LAN IPv4 address').pack(anchor='w')
        ttk.Entry(setup, textvariable=self.mac_ip).pack(fill='x', pady=(2, 8))
        ttk.Label(setup, text='Coordinator public key (ssh-ed25519 …; never paste a private key)').pack(anchor='w')
        self.key = tk.Text(setup, height=3, wrap='word')
        self.key.pack(fill='x', pady=(2, 8))
        ttk.Button(setup, text='Set up LAN connection…', command=self.setup).pack(anchor='w')
        self.connection = tk.Text(setup, height=7, wrap='word', state='disabled')
        self.connection.pack(fill='both', expand=True, pady=(12, 0))
        self.log_text = tk.Text(log_frame, wrap='word', state='disabled')
        self.log_text.pack(fill='both', expand=True)
        self.last_log = None
        root.protocol('WM_DELETE_WINDOW', self.close)
        threading.Thread(target=self.poll_metrics, daemon=True).start()
        self.refresh()
        if (Path.home() / '.dyno' / 'worker-discovery-enabled').exists():
            self.background(self.start_discovery)

    def background(self, fn):
        if self.busy:
            return
        self.busy = True
        def work():
            try:
                fn()
            except Exception as exc:
                self.worker.log(str(exc))
                self.events.put(('status', str(exc)))
            finally:
                self.busy = False
        threading.Thread(target=work, daemon=True).start()

    def start(self):
        device = self.device.get()
        self.background(lambda: self.worker.start(bundled_binary(), device))

    def stop(self):
        if self.worker.snapshot()['state'] in ('Starting', 'Listening'):
            if not messagebox.askyesno('Stop worker?', 'This interrupts any pool request using this GPU. Stop now?'):
                return
        self.background(self.worker.stop)

    def poll_metrics(self):
        import time
        while not self.closing:
            try:
                self.gpus = gpu_inventory()
                self.gpu_error = '' if self.gpus else 'No NVIDIA GPU was found.'
            except Exception as exc:
                self.gpus = []
                self.gpu_error = 'NVIDIA metrics unavailable: ' + str(exc)
            time.sleep(3)

    def refresh(self):
        while not self.events.empty():
            kind, value = self.events.get_nowait()
            if kind == 'status':
                self.discovery_status.set(value)
            elif kind == 'interfaces':
                self.networks.configure(values=value)
                if len(value) == 1:
                    self.selected_network = value[0]
                    self.network_choice.set(value[0])
            elif kind == 'confirm':
                code, name, event, answer = value
                answer.append(messagebox.askyesno('Verify coordinator',
                    f'Pair with {name}?\n\n{code}\n\nConfirm only if every group matches on the coordinator.', parent=self.root))
                event.set()
        if self.pair_server and self.pair_server.stopped.is_set():
            self.stop_discovery(announce=False)
        snapshot = self.worker.snapshot()
        self.status.set(f"{snapshot['state']} · {snapshot['uptime_seconds']}s" +
                        (f" · {snapshot['error']}" if snapshot['error'] else ''))
        values = [gpu['device'] for gpu in self.gpus]
        if values:
            self.devices.configure(values=values)
        gpu = next((g for g in self.gpus if g['device'] == self.device.get()), None)
        def display(value):
            return 'unavailable' if value is None else str(value)
        self.metrics.set((f"{gpu['name']} · VRAM {display(gpu['used_mib'])}/{display(gpu['total_mib'])} MiB · "
                          f"GPU {display(gpu['utilization'])}% · {display(gpu['temperature'])}°C · driver {gpu['driver']}")
                         if gpu else getattr(self, 'gpu_error', 'Checking NVIDIA driver…'))
        running = snapshot['state'] in ('Starting', 'Listening', 'Stopping')
        self.start_button.configure(state='disabled' if self.busy or running or not values else 'normal')
        self.stop_button.configure(state='normal' if running and not self.busy else 'disabled')
        self.devices.configure(state='disabled' if running else 'readonly')
        text = '\n'.join(snapshot['logs'])
        if text != self.last_log:
            self.log_text.configure(state='normal')
            self.log_text.delete('1.0', 'end')
            self.log_text.insert('end', text)
            self.log_text.see('end')
            self.log_text.configure(state='disabled')
            self.last_log = text
        if not self.closing:
            self.root.after(500, self.refresh)

    def setup(self):
        if self.busy:
            return
        self.setup_result = 'Setup failed. See Runtime log for details.'
        from .worker_setup import setup_request, launch_setup
        try:
            request = setup_request(self.mac_ip.get(), self.key.get('1.0', 'end'))
        except ValueError as exc:
            messagebox.showerror('Connection details', str(exc))
            return
        if not messagebox.askyesno('Set up Windows SSH?', 'This installs/enables OpenSSH, adds a firewall rule for this coordinator, '
                                  'and adds a restricted public key for your Windows account. Continue?'):
            return
        def work():
            result = launch_setup(request)
            self.worker.log(result)
            self.setup_result = result
        self.background(work)
        self.show_setup_result()

    def show_setup_result(self):
        if self.busy:
            self.root.after(500, self.show_setup_result)
            return
        self.connection.configure(state='normal')
        self.connection.delete('1.0', 'end')
        self.connection.insert('end', getattr(self, 'setup_result', 'Setup failed. See Runtime log for details.'))
        self.connection.configure(state='disabled')

    def export(self):
        path = filedialog.asksaveasfilename(defaultextension='.json', initialfile='dyno-worker-diagnostics.json')
        if path:
            Path(path).write_text(json.dumps(dict(worker=self.worker.snapshot(), gpus=self.gpus), indent=2), encoding='utf-8')

    def enable_discovery(self):
        def work():
            from .worker_setup import launch_elevated
            result = launch_elevated({'program': sys.executable}, 'setup-discovery.ps1')
            marker = Path.home() / '.dyno' / 'worker-discovery-enabled'
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text('enabled', encoding='ascii')
            self.worker.log(result)
            self.start_discovery()
        self.background(work)

    def start_discovery(self):
        from .discovery import Advertisement, PAIR_PORT, local_interfaces, peer_on_lan, safe_label
        from .pairing import PairingServer
        self.stop_discovery(announce=False)
        interfaces = local_interfaces()
        self.events.put(('interfaces', [i['interface'] for i in interfaces]))
        if not interfaces:
            self.events.put(('status', 'No Private LAN found. Set your trusted LAN to Private, then enable discovery.'))
            return
        # Restrict the listener and advertisements to one concrete interface.
        interface = next((i for i in interfaces if i['interface'] == self.selected_network), None)
        if interface is None:
            if len(interfaces) > 1:
                self.events.put(('status', 'Choose the Private local network shared with your coordinator, then open pairing.'))
                return
            interface = interfaces[0]
        def allowed(peer):
            return any(i['address'] == interface['address'] and peer_on_lan(peer, i) for i in local_interfaces())
        def confirm(code, name, stopped):
            event, answer = threading.Event(), []
            self.events.put(('confirm', (code, safe_label(name), event, answer)))
            for _ in range(110):
                if event.wait(1):
                    return bool(answer and answer[0])
                if stopped.is_set() or self.closing:
                    return False
            return False
        def install(request):
            from .worker_setup import launch_setup
            self.busy = True
            try:
                self.events.put(('status', 'Codes confirmed. Approve Windows connection setup to finish pairing.'))
                return json.loads(launch_setup(request | {'automatic': True}))
            finally:
                self.busy = False
        try:
            self.pair_server = PairingServer(interface['address'], PAIR_PORT, allowed, confirm, install,
                lambda value: self.events.put(('status', value)))
            gpu = self.gpus[0]['name'] if self.gpus else 'NVIDIA GPU'
            self.advertisement = Advertisement(interface, socket.gethostname(), gpu)
            self.events.put(('status', f'Discoverable on {interface["interface"]} for 5 minutes. Open Nearby workers on your coordinator.'))
            server = self.pair_server
            def watch_interface():
                while not server.stopped.wait(5):
                    try:
                        valid = any(i['address'] == interface['address'] for i in local_interfaces())
                    except Exception:
                        valid = False
                    if not valid:
                        self.events.put(('status', 'Discovery stopped because the Private LAN changed.'))
                        server.close()
                        break
            threading.Thread(target=watch_interface, daemon=True).start()
        except Exception as exc:
            self.stop_discovery()
            self.events.put(('status', 'Discovery unavailable: ' + str(exc)))

    def stop_discovery(self, announce=True):
        if self.pair_server:
            self.pair_server.close()
            self.pair_server = None
        if self.advertisement:
            self.advertisement.close()
            self.advertisement = None
        if announce:
            self.events.put(('status', 'Discovery stopped. Open pairing when you want to connect another coordinator.'))

    def close(self):
        if self.busy:
            messagebox.showinfo('Operation in progress', 'Wait for the current operation to finish before quitting.')
            return
        if self.worker.snapshot()['state'] == 'Listening' and not messagebox.askyesno('Quit worker?', 'Quit and interrupt active pool requests?'):
            return
        self.closing = True
        self.stop_discovery()
        self.background(self.worker.stop)
        self.finish_close()

    def finish_close(self):
        if self.busy:
            self.root.after(100, self.finish_close)
        else:
            self.root.destroy()


def main():
    root = tk.Tk()
    if sys.platform != 'win32':
        root.withdraw()
        messagebox.showerror('Windows worker', 'This desktop companion currently targets native Windows with NVIDIA CUDA.')
        root.destroy()
        return 1
    WorkerApp(root)
    root.mainloop()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
