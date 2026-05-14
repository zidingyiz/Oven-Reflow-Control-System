import tkinter as tk
from tkinter import ttk, messagebox
import serial
import time
import csv
from datetime import datetime

# --- Matplotlib ---
import matplotlib
matplotlib.use("TkAgg")
from matplotlib.figure import Figure
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg


PORT = "COM10"     # Serial port
BAUD = 115200      # Baud rate


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Reflow UART: Profile + Temp Graph + CSV Log")
        self.resizable(False, False)

        # ---------------- Serial Initialization ----------------
        self.ser = None
        try:
            self.ser = serial.Serial(PORT, BAUD, timeout=0.05)
            # Disable auto-reset signals
            self.ser.dtr = False
            self.ser.rts = False
            time.sleep(0.2)
            self.status = tk.StringVar(value=f"Connected: {PORT} @ {BAUD}")
        except Exception as e:
            self.status = tk.StringVar(value=f"Serial open failed: {e}")

        # ---------------- UI State Variables ----------------

        self.temp_str = tk.StringVar(value="---.-")  # Temperature display
        self.logging = False                         # Logging flag
        self.start_monotonic = None                  # Start time reference

        # ---------------- CSV Logging ----------------
        self.csv_file = None
        self.csv_writer = None

        # Serial receive buffer
        self.rx_buf = bytearray()

        # Data arrays for plotting
        self.t_data = []
        self.y_data = []

        # Profile parameters default values
        self.soak_temp = tk.StringVar(value="150")
        self.soak_time = tk.StringVar(value="090")
        self.refl_temp = tk.StringVar(value="230")
        self.refl_time = tk.StringVar(value="040")

        # ---------------- UI Layout ----------------
        frm = ttk.Frame(self, padding=12)
        frm.grid(row=0, column=0, sticky="nsew")

        # Helper function to create labeled input rows
        def add_row(r, label, var):
            ttk.Label(frm, text=label).grid(row=r, column=0, sticky="e", padx=8, pady=6)
            ent = ttk.Entry(frm, textvariable=var, width=6)
            ent.grid(row=r, column=1, sticky="w", padx=8, pady=6)
            ttk.Label(frm, text="(000..999)").grid(row=r, column=2, sticky="w")
            ent.bind("<Return>", self.send_profile)
            return ent

        add_row(0, "Soak temperature:", self.soak_temp)
        add_row(1, "Soak time:",        self.soak_time)
        add_row(2, "Reflow temperature:", self.refl_temp)
        add_row(3, "Reflow time:",        self.refl_time)

        # Buttons
        btn_row = ttk.Frame(frm)
        btn_row.grid(row=4, column=0, columnspan=3, pady=(6, 10), sticky="w")

        ttk.Button(btn_row, text="Send Profile", command=self.send_profile).grid(row=0, column=0, padx=(0, 8))

        self.btn_start = ttk.Button(btn_row, text="Start", command=self.start_logging)
        self.btn_start.grid(row=0, column=1, padx=(0, 8))

        self.btn_stop = ttk.Button(btn_row, text="Stop", command=self.stop_logging, state="disabled")
        self.btn_stop.grid(row=0, column=2)

        ttk.Separator(frm).grid(row=5, column=0, columnspan=3, sticky="ew", pady=10)

        # ---------------- Temperature Display ----------------
        ttk.Label(frm, text="Temperature:").grid(row=6, column=0, sticky="e", padx=8, pady=4)
        ttk.Label(frm, textvariable=self.temp_str, font=("Consolas", 14)).grid(row=6, column=1, sticky="w", padx=8, pady=4)
        ttk.Label(frm, text="C").grid(row=6, column=2, sticky="w")

        # ---------------- Matplotlib Plot ----------------
        self.fig = Figure(figsize=(6.6, 3.2), dpi=100)
        self.ax = self.fig.add_subplot(111)
        self.ax.set_xlabel("Time (s)")
        self.ax.set_ylabel("Temperature (C)")
        self.line, = self.ax.plot([], [])
        self.ax.grid(True)

        canvas = FigureCanvasTkAgg(self.fig, master=frm)
        canvas_widget = canvas.get_tk_widget()
        canvas_widget.grid(row=7, column=0, columnspan=3, pady=(8, 0))
        self.canvas = canvas

        ttk.Label(frm, textvariable=self.status).grid(row=8, column=0, columnspan=3, sticky="w", pady=(10, 0))

        self.protocol("WM_DELETE_WINDOW", self.on_close)

        # Start periodic tasks
        self.after(50, self.poll_serial)   # Serial polling
        self.after(200, self.update_plot)  # Plot refreshing

    # Format input as 3-digit number (000–999)
    def fmt3(self, s: str) -> str:
        s = s.strip()
        if not s.isdigit():
            raise ValueError("Digits only")
        n = int(s)
        if n < 0 or n > 999:
            raise ValueError("Range must be 000..999")
        return f"{n:03d}"

    # Send profile parameters to MCU over UART
    def send_profile(self, event=None):
        if not self.ser:
            messagebox.showerror("Serial", "Serial port is not open.")
            return
        try:
            st = self.fmt3(self.soak_temp.get())
            sd = self.fmt3(self.soak_time.get())
            rt = self.fmt3(self.refl_temp.get())
            rd = self.fmt3(self.refl_time.get())
        except ValueError as e:
            messagebox.showerror("Input error", str(e))
            return

        payload = f"ST={st}\nSD={sd}\nRT={rt}\nRD={rd}\n".encode("ascii")
        try:
            self.ser.write(payload)
            self.ser.flush()
            self.status.set(f"Sent ST={st} SD={sd} RT={rt} RD={rd}")
        except Exception as e:
            self.status.set(f"Send failed: {e}")

    # Start temperature logging + CSV recording
    def start_logging(self):
        if not self.ser:
            messagebox.showerror("Serial", "Serial port is not open.")
            return

        self.t_data.clear()
        self.y_data.clear()
        self.start_monotonic = time.monotonic()
        self.logging = True

        # Create timestamped CSV file
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"reflow_log_{ts}.csv"
        try:
            self.csv_file = open(filename, "w", newline="")
            self.csv_writer = csv.writer(self.csv_file)
            self.csv_writer.writerow(["time_s", "temperature_C"])
            self.csv_file.flush()
        except Exception as e:
            self.logging = False
            self.start_monotonic = None
            messagebox.showerror("CSV", f"Failed to open CSV file:\n{e}")
            return

        self.status.set(f"Logging started → {filename}")
        self.btn_start.config(state="disabled")
        self.btn_stop.config(state="normal")

    # Stop logging and close CSV file
    def stop_logging(self):
        self.logging = False
        self.start_monotonic = None

        try:
            if self.csv_file:
                self.csv_file.flush()
                self.csv_file.close()
        except:
            pass

        self.csv_file = None
        self.csv_writer = None

        self.status.set("Logging stopped.")
        self.btn_start.config(state="normal")
        self.btn_stop.config(state="disabled")

    # Continuously poll serial port for new temperature data
    def poll_serial(self):
        if self.ser:
            try:
                data = self.ser.read(256)
                if data:
                    self.rx_buf.extend(data)

                    while b"\n" in self.rx_buf:
                        line, _, rest = self.rx_buf.partition(b"\n")
                        self.rx_buf = bytearray(rest)

                        line = line.replace(b"\r", b"")
                        s = line.decode("ascii", errors="ignore").strip()

                        # Expected format: T=123.4
                        if s.startswith("T=") and len(s) >= 7:
                            t = s[2:7]
                            if len(t) == 5 and t[0:3].isdigit() and t[3] == "." and t[4].isdigit():
                                self.temp_str.set(t)

                                # If logging, store data + write to CSV
                                if self.logging and self.start_monotonic is not None:
                                    now = time.monotonic()
                                    tsec = now - self.start_monotonic
                                    tempC = float(t)

                                    self.t_data.append(tsec)
                                    self.y_data.append(tempC)

                                    if self.csv_writer:
                                        self.csv_writer.writerow([f"{tsec:.3f}", f"{tempC:.1f}"])
                                        if self.csv_file:
                                            self.csv_file.flush()

            except Exception as e:
                self.status.set(f"Serial read error: {e}")

        self.after(50, self.poll_serial)

    # Refresh plot periodically
    def update_plot(self):
        self.line.set_data(self.t_data, self.y_data)

        if len(self.t_data) >= 2:
            xmin = max(0.0, self.t_data[-1] - 300.0)  # Show last 5 minutes
            xmax = max(10.0, self.t_data[-1] + 1.0)
            self.ax.set_xlim(xmin, xmax)

            ymin = min(self.y_data)
            ymax = max(self.y_data)
            pad = max(1.0, (ymax - ymin) * 0.1)
            self.ax.set_ylim(ymin - pad, ymax + pad)
        else:
            self.ax.set_xlim(0, 60)
            self.ax.set_ylim(0, 260)

        self.canvas.draw_idle()
        self.after(200, self.update_plot)

    # Cleanup on window close
    def on_close(self):
        try:
            if self.ser:
                self.ser.close()
        except:
            pass
        try:
            if self.csv_file:
                self.csv_file.close()
        except:
            pass
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
