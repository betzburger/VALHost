#pragma once
#include <memory>

class JuceInitializer
{
public:
    JuceInitializer();
    ~JuceInitializer();
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
