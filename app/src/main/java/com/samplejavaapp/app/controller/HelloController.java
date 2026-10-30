package com.samplejavaapp.app.controller;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private static final Logger LOGGER = LoggerFactory.getLogger(HelloController.class);

    /**
     * Echoes the {@code val} query parameter back to the caller, prefixed with
     * {@code QueryStringValue: }. A missing parameter is a 400.
     */
    @GetMapping("/api/foos")
    public String getFoos(@RequestParam String val) {
        String result = "QueryStringValue: " + val;
        LOGGER.info("responding to /api/foos: {}", result);
        return result;
    }

    @GetMapping("/api/release")
    public String getRelease() {
        return "Lab CI/CD metrics 1.2.16";
    }
}
