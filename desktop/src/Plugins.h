// Plugins.h - third-party effect plugins (PRD § 5.5, § 11.5): VST3 and LV2 (and Audio Units on macOS).
//
// A slot per bus (delay, reverb, bus 3) and per stem strip (its insert). A plugin in a slot takes the place
// of the built-in effect in the engine's path. Its knobs on the console are macros: the bus's knobs of the FX
// page (five per bus), the strip's three knobs of the INSERTS page, each given one of the plugin's parameters.
// A macro IS the engine's parameter under that knob, mirrored to the plugin: so the MIDImix, its soft
// takeover and the screen all work as for a built-in effect, and a change made in the plugin's own window
// comes back to the knob.
//
// Plugins run inside the app (JUCE has no ready-made separate process): one that crashes takes the app down.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include "Engine.h"

#include <juce_audio_processors/juce_audio_processors.h>

#include <functional>
#include <map>
#include <thread>

namespace dsm {

// A plugin as the engine calls it: stereo in, stereo out.
class HostedPlugin : public Processor
{
public:
    std::unique_ptr<juce::AudioProcessor> processor;
    juce::String name, identifier, description;   // description: what finds the plugin again, as XML

    void prepare()
    {
        processor->enableAllBuses();
        processor->setRateAndBufferSizeDetails(kRate, kChunk);
        processor->prepareToPlay(kRate, kChunk);
        const int channels = juce::jmax(2, processor->getTotalNumInputChannels(), processor->getTotalNumOutputChannels());
        scratch_.setSize(channels, kChunk);
    }

    void process(float* left, float* right, int frames) override
    {
        if (frames > scratch_.getNumSamples()) return;
        scratch_.clear();
        scratch_.copyFrom(0, 0, left, frames);
        scratch_.copyFrom(1, 0, right, frames);
        juce::AudioBuffer<float> block(scratch_.getArrayOfWritePointers(), scratch_.getNumChannels(), frames);
        midi_.clear();
        const juce::ScopedLock lock(processor->getCallbackLock());
        if (processor->isSuspended()) return;
        processor->processBlock(block, midi_);
        const bool monoOut = processor->getTotalNumOutputChannels() < 2;
        std::memcpy(left, scratch_.getReadPointer(0), sizeof(float) * (size_t)frames);
        std::memcpy(right, scratch_.getReadPointer(monoOut ? 0 : 1), sizeof(float) * (size_t)frames);
    }

    juce::AudioProcessorParameter* parameter(int index) const
    {
        const auto& all = processor->getParameters();
        return index >= 0 && index < all.size() ? all[index] : nullptr;
    }

private:
    juce::AudioBuffer<float> scratch_;
    juce::MidiBuffer midi_;
};

// The plugin's own window; closing it only hides it.
class PluginWindow : public juce::DocumentWindow
{
public:
    explicit PluginWindow(HostedPlugin& plugin) : juce::DocumentWindow(plugin.name, juce::Colour(0xff1e1a17), juce::DocumentWindow::closeButton)
    {
        juce::AudioProcessorEditor* editor = plugin.processor->hasEditor() ? plugin.processor->createEditorIfNeeded() : nullptr;
        if (editor == nullptr) editor = new juce::GenericAudioProcessorEditor(*plugin.processor);   // a plain list of its settings
        setUsingNativeTitleBar(true);
        setContentOwned(editor, true);
        setResizable(editor->isResizable(), false);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
    }
    void closeButtonPressed() override { setVisible(false); }
};

struct Slot
{
    static constexpr int kBusMacros = 5, kInsertMacros = 3;

    bool isBus = true;
    int index = 0;                         // bus (delay, reverb, bus 3) or stem strip
    std::unique_ptr<HostedPlugin> plugin;
    std::vector<int> macros;               // the plugin parameter under each macro knob, -1: none yet
    std::vector<float> sent;               // the value last passed between the knob and the plugin
    std::unique_ptr<PluginWindow> window;
    juce::var kept;                        // a plugin of the project that is not installed here: left as it was read

    int macroCount() const { return isBus ? kBusMacros : kInsertMacros; }
    bool holdsPlugin() const { return plugin != nullptr; }
    juce::String missingName() const { return plugin == nullptr && kept.isObject() ? kept["name"].toString() : juce::String(); }

    // The engine parameter a macro rides on: the FX page's knob for a bus, the INSERTS page's for a strip.
    int engineParam(int macro) const
    {
        const Engine& engine = Engine::get();
        if (!isBus) return engine.insertValue[index][macro];
        return engine.effect[fx::kFxLayout[index * 2 + macro / 3][macro % 3]];
    }

    juce::String macroName(int macro) const
    {
        juce::AudioProcessorParameter* p = plugin != nullptr ? plugin->parameter(macros[(size_t)macro]) : nullptr;
        return p != nullptr ? p->getName(18).toUpperCase() : juce::String();
    }
    juce::String macroText(int macro) const
    {
        juce::AudioProcessorParameter* p = plugin != nullptr ? plugin->parameter(macros[(size_t)macro]) : nullptr;
        return p != nullptr ? p->getCurrentValueAsText().substring(0, 12) + (p->getLabel().isNotEmpty() ? " " + p->getLabel() : juce::String()) : juce::String();
    }
};

class PluginHost
{
public:
    Slot bus[3], insert[kStems];
    std::atomic<bool> scanning{false};
    juce::String scanningName;
    // Remembers, per plugin, which parameters its macros hold (PRD § 5.5): given by the app's settings.
    std::function<juce::String(const juce::String& plugin)> recallMacros;
    std::function<void(const juce::String& plugin, const juce::String& macros)> rememberMacros;

    explicit PluginHost(const juce::File& folder) : listFile_(folder.getChildFile("plugins.xml")), pedal_(folder.getChildFile("plugins-scan.txt"))
    {
        formats_.addDefaultFormats();
        if (const std::unique_ptr<juce::XmlElement> xml = juce::parseXML(listFile_)) known_.recreateFromXml(*xml);
        for (int b = 0; b < 3; ++b) { bus[b].isBus = true; bus[b].index = b; reset(bus[b]); }
        for (int s = 0; s < kStems; ++s) { insert[s].isBus = false; insert[s].index = s; reset(insert[s]); }
    }

    ~PluginHost()
    {
        if (scanner_.joinable()) scanner_.join();
        for (Slot& slot : bus) clear(slot);
        for (Slot& slot : insert) clear(slot);
    }

    // A plugin built into the app, offered like an installed one (the tests' own plugin).
    void addInternal(const juce::String& name, std::function<std::unique_ptr<juce::AudioProcessor>()> make)
    {
        internal_["internal:" + name] = {name, std::move(make)};
    }

    // ---- What is installed ----

    struct Choice { juce::String name, manufacturer, identifier; };

    std::vector<Choice> choices() const
    {
        std::vector<Choice> all;
        for (const auto& entry : internal_) all.push_back({entry.second.name, "DubStemMix", entry.first});
        for (const juce::PluginDescription& d : known_.getTypes())
            if (isEffect(d)) all.push_back({d.name + " (" + d.pluginFormatName + ")", d.manufacturerName, d.createIdentifierString()});
        std::sort(all.begin(), all.end(), [](const Choice& a, const Choice& b)
        {
            const int byMaker = a.manufacturer.compareIgnoreCase(b.manufacturer);
            return byMaker != 0 ? byMaker < 0 : a.name.compareIgnoreCase(b.name) < 0;
        });
        return all;
    }

    // Effects only: no instrument, and none of the mixers, generators, panners and converters Audio Units also list.
    static bool isEffect(const juce::PluginDescription& d)
    {
        if (d.isInstrument) return false;
        for (const char* other : {"Generator", "Mixer", "Panner", "Output", "Converter", "Offline", "Synth"})
            if (d.category.containsIgnoreCase(other)) return false;
        return true;
    }

    // Looks for the plugins installed, in the background. A plugin that crashed a previous scan is skipped.
    void scan()
    {
        if (scanning.exchange(true)) return;
        if (scanner_.joinable()) scanner_.join();
        scanner_ = std::thread([this]
        {
            for (juce::AudioPluginFormat* format : formats_.getFormats())
            {
                juce::PluginDirectoryScanner scanner(known_, *format, format->getDefaultLocationsToSearch(), true, pedal_);
                juce::String name;
                while (scanner.scanNextFile(true, name)) scanningName = name.fromLastOccurrenceOf("/", false, false);
            }
            if (const std::unique_ptr<juce::XmlElement> xml = known_.createXml()) xml->writeTo(listFile_);
            scanningName = {};
            scanning.store(false);
        });
    }

    // ---- Slots ----

    // Puts a plugin in a slot ("" = the built-in effect again). False, with `error`, when it cannot be loaded.
    bool set(Slot& slot, const juce::String& identifier, juce::String& error)
    {
        if (identifier.isEmpty()) { clear(slot); slot.kept = juce::var(); return true; }
        std::unique_ptr<HostedPlugin> plugin = make(identifier, error);
        if (plugin == nullptr) return false;
        install(slot, std::move(plugin));
        slot.kept = juce::var();
        // The parameters its macros held last time, in any song.
        const juce::StringArray remembered = juce::StringArray::fromTokens(recallMacros ? recallMacros(identifier) : juce::String(), ",", "");
        for (int i = 0; i < slot.macroCount(); ++i) assign(slot, i, i < remembered.size() ? remembered[i].getIntValue() : -1, false);
        return true;
    }

    // Gives a macro one of the plugin's parameters (-1: none). The knob takes the plugin's value: nothing jumps.
    void assign(Slot& slot, int macro, int parameter, bool remember = true)
    {
        if (slot.plugin == nullptr) return;
        slot.macros[(size_t)macro] = slot.plugin->parameter(parameter) != nullptr ? parameter : -1;
        if (juce::AudioProcessorParameter* p = slot.plugin->parameter(parameter))
        {
            slot.sent[(size_t)macro] = p->getValue();
            Engine::get().set(slot.engineParam(macro), p->getValue());
        }
        if (remember && rememberMacros)
        {
            juce::StringArray list;
            for (int m : slot.macros) list.add(juce::String(m));
            rememberMacros(slot.plugin->identifier, list.joinIntoString(","));
        }
    }

    void showWindow(Slot& slot)
    {
        if (slot.plugin == nullptr) return;
        if (slot.window == nullptr) slot.window = std::make_unique<PluginWindow>(*slot.plugin);
        slot.window->setVisible(true);
        slot.window->toFront(true);
    }

    // Called many times a second: a knob moved goes to the plugin, a setting changed in the plugin's own
    // window comes back to the knob.
    void sync()
    {
        Engine& engine = Engine::get();
        auto each = [&engine](Slot& slot)
        {
            if (slot.plugin == nullptr) return;
            for (int i = 0; i < slot.macroCount(); ++i)
            {
                juce::AudioProcessorParameter* p = slot.plugin->parameter(slot.macros[(size_t)i]);
                if (p == nullptr) continue;
                const int target = slot.engineParam(i);
                const float knob = engine.value(target), inPlugin = p->getValue();
                float& sent = slot.sent[(size_t)i];
                if (std::fabs(knob - sent) > 1e-4f) { p->setValueNotifyingHost(knob); sent = knob; }
                else if (std::fabs(inPlugin - sent) > 0.002f) { engine.set(target, inPlugin); sent = inPlugin; }
            }
        };
        for (Slot& slot : bus) each(slot);
        for (Slot& slot : insert) each(slot);
    }

    // ---- In a project: under the app's own key, never in the Mac's Audio Unit entries ----

    juce::var save() const
    {
        auto entry = [](const Slot& slot) -> juce::var
        {
            if (slot.plugin == nullptr) return slot.kept;   // not installed here: as it was read
            auto* o = new juce::DynamicObject();
            o->setProperty("plugin", slot.plugin->identifier);
            o->setProperty("name", slot.plugin->name);
            o->setProperty("description", slot.plugin->description);
            juce::MemoryBlock state;
            slot.plugin->processor->getStateInformation(state);
            o->setProperty("state", state.toBase64Encoding());
            juce::Array<juce::var> macros;
            for (int m : slot.macros) macros.add(m);
            o->setProperty("macros", macros);
            return juce::var(o);
        };
        static const char* keys[3] = {"delay", "reverb", "bus3"};
        auto* slots = new juce::DynamicObject();
        auto* inserts = new juce::DynamicObject();
        for (int b = 0; b < 3; ++b) if (const juce::var v = entry(bus[b]); v.isObject()) slots->setProperty(keys[b], v);
        for (int s = 0; s < kStems; ++s) if (const juce::var v = entry(insert[s]); v.isObject()) inserts->setProperty(juce::Identifier(juce::String(s)), v);
        auto* o = new juce::DynamicObject();
        o->setProperty("slots", juce::var(slots));
        o->setProperty("inserts", juce::var(inserts));
        return juce::var(o);
    }

    // Loads a project's plugins. Returns the names of those not installed here (they stay in the project).
    juce::StringArray load(const juce::var& saved)
    {
        juce::StringArray missing;
        auto each = [this, &missing](Slot& slot, const juce::var& entry)
        {
            const juce::String identifier = entry["plugin"].toString();
            if (identifier.isEmpty()) { clear(slot); slot.kept = juce::var(); return; }
            juce::String error;
            // The same plugin already in the slot stays plugged: only its settings change, its tail rings on (PRD § 5.8).
            if (slot.plugin == nullptr || slot.plugin->identifier != identifier)
            {
                std::unique_ptr<HostedPlugin> plugin = make(identifier, error, entry["description"].toString());
                if (plugin == nullptr)
                {
                    clear(slot);
                    slot.kept = entry;
                    missing.add(entry["name"].toString());
                    return;
                }
                install(slot, std::move(plugin));
            }
            slot.kept = juce::var();
            juce::MemoryBlock state;
            if (state.fromBase64Encoding(entry["state"].toString()) && state.getSize() > 0)
                slot.plugin->processor->setStateInformation(state.getData(), (int)state.getSize());
            const juce::Array<juce::var>* macros = entry["macros"].getArray();
            for (int i = 0; i < slot.macroCount(); ++i) assign(slot, i, macros != nullptr && i < macros->size() ? (int)(*macros)[i] : -1, false);
        };
        static const char* keys[3] = {"delay", "reverb", "bus3"};
        for (int b = 0; b < 3; ++b) each(bus[b], saved["slots"][juce::Identifier(keys[b])]);
        for (int s = 0; s < kStems; ++s) each(insert[s], saved["inserts"][juce::Identifier(juce::String(s))]);
        return missing;
    }

private:
    struct Internal { juce::String name; std::function<std::unique_ptr<juce::AudioProcessor>()> make; };

    void reset(Slot& slot)
    {
        slot.macros.assign((size_t)slot.macroCount(), -1);
        slot.sent.assign((size_t)slot.macroCount(), 0.0f);
    }

    std::atomic<Processor*>& hook(const Slot& slot) { return slot.isBus ? hooks().bus[slot.index] : hooks().insert[slot.index]; }

    std::unique_ptr<HostedPlugin> make(const juce::String& identifier, juce::String& error, const juce::String& descriptionXml = {})
    {
        auto plugin = std::make_unique<HostedPlugin>();
        plugin->identifier = identifier;
        const auto internal = internal_.find(identifier);
        if (internal != internal_.end())
        {
            plugin->processor = internal->second.make();
            plugin->name = internal->second.name;
        }
        else
        {
            juce::PluginDescription description;
            bool found = false;
            for (const juce::PluginDescription& d : known_.getTypes())
                if (d.createIdentifierString() == identifier) { description = d; found = true; break; }
            // Not in the list scanned here, but the project says where it is: try that.
            if (!found)
                if (const std::unique_ptr<juce::XmlElement> xml = juce::parseXML(descriptionXml)) found = description.loadFromXml(*xml);
            if (!found) { error = "the plugin is not installed"; return nullptr; }
            plugin->processor = formats_.createPluginInstance(description, kRate, kChunk, error);
            plugin->name = description.name;
            if (const std::unique_ptr<juce::XmlElement> xml = description.createXml()) plugin->description = xml->toString();
        }
        if (plugin->processor == nullptr) { if (error.isEmpty()) error = "the plugin cannot be loaded"; return nullptr; }
        plugin->prepare();
        return plugin;
    }

    void install(Slot& slot, std::unique_ptr<HostedPlugin> plugin)
    {
        slot.window.reset();
        Processor* fresh = plugin.get();
        hook(slot).store(fresh, std::memory_order_release);
        retire(std::move(slot.plugin));
        slot.plugin = std::move(plugin);
        reset(slot);
        // An insert plugin rides on the strip's three INSERTS knobs: the engine keeps them alive.
        if (!slot.isBus) Engine::get().setChoice(Engine::get().insert[slot.index], fx::insert::Wah, fx::insert::KindCount);
    }

    void clear(Slot& slot)
    {
        slot.window.reset();
        if (slot.plugin == nullptr) return;
        hook(slot).store(nullptr, std::memory_order_release);
        retire(std::move(slot.plugin));
        reset(slot);
        if (!slot.isBus) Engine::get().setChoice(Engine::get().insert[slot.index], fx::insert::None, fx::insert::KindCount);
    }

    // The audio thread may still be inside the plugin taken out: it is let go a moment later.
    static void retire(std::unique_ptr<HostedPlugin> old)
    {
        if (old == nullptr) return;
        juce::Thread::sleep(40);
        old->processor->releaseResources();
    }

    juce::AudioPluginFormatManager formats_;
    juce::KnownPluginList known_;
    juce::File listFile_, pedal_;
    std::map<juce::String, Internal> internal_;
    std::thread scanner_;
};

} // namespace dsm
