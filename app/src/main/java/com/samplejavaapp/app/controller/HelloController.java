package com.samplejavaapp.app.controller;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private static final Logger logger = LoggerFactory.getLogger(HelloController.class);

    @GetMapping("/api/foos")
    @ResponseBody
    public String getFoos(@RequestParam String val) {
        String result = "QueryStringValue: " + val;
        logger.info(result);
        return result;
    }
}
