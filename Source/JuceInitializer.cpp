#include "JuceInitializer.h"
#include <JuceHeader.h>

struct JuceInitializer::Impl
{
    juce::ScopedJuceInitialiser_GUI juceInitialiser;
};

JuceInitializer::JuceInitializer()
    : impl (std::make_unique<Impl>())
{}

JuceInitializer::~JuceInitializer()
{
    impl = nullptr;
}
