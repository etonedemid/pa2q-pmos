// Hand-written (no build step): Decky's legacy plugin format, an expression evaluating
// to the plugin factory. DFL and SP_REACT are globals Decky provides.
(function (DFL, React) {
    "use strict";
    const h = React.createElement;
    const OPTIONS = [
        { data: "battery", label: "Battery" },
        { data: "balanced", label: "Balanced" },
        { data: "performance", label: "Performance" },
        { data: "max", label: "Max" },
    ];
    const DEFAULT = "balanced";

    function presetRow(label, value, onChange) {
        return h(DFL.PanelSectionRow, { key: label },
            h(DFL.DropdownItem, { label, rgOptions: OPTIONS, selectedOption: value, onChange: (o) => onChange(o.data) }));
    }

    function Content({ api }) {
        const [state, setState] = React.useState(null);
        const load = () => api.callPluginMethod("get_state", {}).then((r) => r.success && setState(r.result));
        React.useEffect(() => { load(); }, []);
        if (!state) return null;
        const table = state.table;
        const fallback = table.default || DEFAULT;
        const set = (appid, preset) => {
            setState({ ...state, table: { ...table, [appid]: preset } });
            api.callPluginMethod("set_preset", { appid, preset }).then(load);
        };
        const running = DFL.Router.MainRunningApp;
        const current = running && state.games.find((g) => g.appid === String(running.appid));
        const others = state.games.filter((g) => g !== current);
        const reboot = () => DFL.showModal(h(DFL.ConfirmModal, {
            strTitle: "Reboot to Android?",
            strDescription: "Steam and any running game will close.",
            strOKButtonText: "Reboot",
            onOK: () => api.callPluginMethod("reboot_android", {}),
        }));
        return h(React.Fragment, null,
            h(DFL.PanelSection, { title: "Display" },
                h(DFL.PanelSectionRow, null,
                    h(DFL.SliderField, {
                        label: "Brightness", value: state.brightness, min: 5, max: 100, step: 5, showValue: true,
                        onChange: (percent) => {
                            setState((old) => ({ ...old, brightness: percent }));
                            api.callPluginMethod("set_brightness", { percent });
                        },
                    }))),
            current && h(DFL.PanelSection, { title: "Now playing" },
                presetRow(current.name, table[current.appid] || fallback, (p) => set(current.appid, p))),
            h(DFL.PanelSection, { title: "Clocks" },
                presetRow("Steam and other games", fallback, (p) => set("default", p)),
                others.map((g) => presetRow(g.name, table[g.appid] || fallback, (p) => set(g.appid, p)))),
            h(DFL.PanelSection, { title: "Power" },
                h(DFL.PanelSectionRow, null,
                    h(DFL.ButtonItem, { layout: "below", onClick: reboot }, "Reboot to Android"))));
    }

    const icon = h("svg", { width: "1em", height: "1em", viewBox: "0 0 24 24", fill: "currentColor" },
        h("path", { d: "M12 4a10 10 0 0 0-8.7 15h17.4A10 10 0 0 0 12 4zm1.4 10.4a2 2 0 1 1-2.8-2.8L17 8z" }));

    return DFL.definePlugin((api) => ({
        title: h("div", null, "Phone Controls"),
        content: h(Content, { api }),
        icon,
    }));
})(DFL, SP_REACT);
