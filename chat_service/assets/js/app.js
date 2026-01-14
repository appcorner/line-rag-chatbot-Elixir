import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {}

Hooks.Chart = {
  mounted() {
    this.handleEvent("update_chart", ({data}) => {
      this.updateChart(data)
    })
  },
  updateChart(data) {
    console.log("Chart data:", data)
  }
}

Hooks.AutoRefresh = {
  mounted() {
    this.interval = setInterval(() => {
      this.pushEvent("refresh", {})
    }, 5000)
  },
  destroyed() {
    clearInterval(this.interval)
  }
}

Hooks.ScrollToBottom = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

Hooks.ImageUpload = {
  mounted() {
    this.el.addEventListener("change", (e) => {
      const files = Array.from(e.target.files)
      if (files.length === 0) return

      const maxSize = 5 * 1024 * 1024 // 5MB
      const validFiles = files.filter(f => f.size <= maxSize && f.type.startsWith("image/"))

      if (validFiles.length === 0) {
        alert("Please select valid image files (max 5MB each)")
        return
      }

      Promise.all(validFiles.map(file => this.readFile(file)))
        .then(images => {
          this.pushEvent("add_images", { images })
          this.el.value = "" // Reset input
        })
    })
  },

  readFile(file) {
    return new Promise((resolve) => {
      const reader = new FileReader()
      reader.onload = (e) => {
        resolve({
          name: file.name,
          size: file.size,
          type: file.type,
          data: e.target.result
        })
      }
      reader.readAsDataURL(file)
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

topbar.config({barColors: {0: "#f97316"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()

window.liveSocket = liveSocket

// Handle copy to clipboard events from LiveView
window.addEventListener("phx:copy_to_clipboard", (event) => {
  if (navigator.clipboard) {
    navigator.clipboard.writeText(event.detail.text)
  }
})

let metricsSocket = new Socket("/socket", {params: {token: window.userToken}})
metricsSocket.connect()

let metricsChannel = metricsSocket.channel("metrics:live", {})
metricsChannel.join()
  .receive("ok", resp => { console.log("Joined metrics channel", resp) })
  .receive("error", resp => { console.log("Unable to join metrics", resp) })

metricsChannel.on("metrics_update", payload => {
  window.dispatchEvent(new CustomEvent("metrics_update", {detail: payload}))
})

let trafficChannel = metricsSocket.channel("traffic:live", {})
trafficChannel.join()
  .receive("ok", resp => { console.log("Joined traffic channel", resp) })
  .receive("error", resp => { console.log("Unable to join traffic", resp) })

trafficChannel.on("traffic_update", payload => {
  window.dispatchEvent(new CustomEvent("traffic_update", {detail: payload}))
})
