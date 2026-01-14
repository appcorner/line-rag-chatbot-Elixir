/**
 * @license MIT
 * topbar 2.0.0, 2023-02-04
 * https://buunguyen.github.io/topbar
 * Copyright (c) 2021 Buu Nguyen
 */

var topbar = (function() {
  var canvas, progressTimerId, fadeTimerId, currentProgress, showing;

  var options = {
    autoRun: true,
    barThickness: 3,
    barColors: {
      0: "rgba(26, 188, 156, .9)",
      ".25": "rgba(52, 152, 219, .9)",
      ".50": "rgba(241, 196, 15, .9)",
      ".75": "rgba(230, 126, 34, .9)",
      "1.0": "rgba(211, 84, 0, .9)"
    },
    shadowBlur: 10,
    shadowColor: "rgba(0, 0, 0, .6)",
    className: null
  };

  var repaint = function() {
    canvas.width = window.innerWidth;
    canvas.height = options.barThickness * 5;
    var ctx = canvas.getContext("2d");
    ctx.shadowBlur = options.shadowBlur;
    ctx.shadowColor = options.shadowColor;
    var lineGradient = ctx.createLinearGradient(0, 0, canvas.width, 0);
    for (var stop in options.barColors)
      lineGradient.addColorStop(stop, options.barColors[stop]);
    ctx.lineWidth = options.barThickness;
    ctx.beginPath();
    ctx.moveTo(0, options.barThickness / 2);
    ctx.lineTo(Math.ceil(currentProgress * canvas.width), options.barThickness / 2);
    ctx.strokeStyle = lineGradient;
    ctx.stroke();
  };

  var createCanvas = function() {
    canvas = document.createElement("canvas");
    var style = canvas.style;
    style.position = "fixed";
    style.top = style.left = style.right = style.margin = style.padding = 0;
    style.zIndex = 100001;
    style.display = "none";
    if (options.className) canvas.classList.add(options.className);
    document.body.appendChild(canvas);
    window.addEventListener("resize", repaint);
  };

  return {
    config: function(opts) {
      for (var key in opts)
        if (options.hasOwnProperty(key)) options[key] = opts[key];
    },
    show: function(delay) {
      if (showing) return;
      if (delay) {
        if (fadeTimerId) return;
        fadeTimerId = setTimeout(function() { topbar.show(); }, delay);
      } else {
        showing = true;
        if (fadeTimerId !== null) topbar.hide();
        if (!canvas) createCanvas();
        canvas.style.opacity = 1;
        canvas.style.display = "block";
        topbar.progress(0);
        if (options.autoRun) {
          (function loop() {
            progressTimerId = window.requestAnimationFrame(loop);
            topbar.progress("+" + 0.05 * Math.pow(1 - Math.sqrt(currentProgress), 2));
          })();
        }
      }
    },
    progress: function(to) {
      if (typeof to === "undefined") return currentProgress;
      if (typeof to === "string") {
        to = (to.indexOf("+") >= 0 || to.indexOf("-") >= 0 ? currentProgress : 0) + parseFloat(to);
      }
      currentProgress = to > 1 ? 1 : to;
      if (canvas) repaint();
      return currentProgress;
    },
    hide: function() {
      clearTimeout(fadeTimerId);
      fadeTimerId = null;
      if (!showing) return;
      showing = false;
      if (progressTimerId != null) {
        window.cancelAnimationFrame(progressTimerId);
        progressTimerId = null;
      }
      (function loop() {
        if (topbar.progress("+.1") >= 1) {
          canvas.style.opacity -= 0.05;
          if (canvas.style.opacity <= 0.05) {
            canvas.style.display = "none";
            fadeTimerId = null;
            return;
          }
        }
        setTimeout(loop, 16);
      })();
    }
  };
})();

export default topbar;
