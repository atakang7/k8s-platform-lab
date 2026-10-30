package com.samplejavaapp.app.controller;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(HelloController.class)
class HelloControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void getFoosReturnsExpectedResult() throws Exception {
        String testValue = "testData123";
        mockMvc.perform(get("/api/foos").param("val", testValue))
                .andExpect(status().isOk())
                .andExpect(content().string("QueryStringValue: " + testValue));
    }

    @Test
    void getFoosMissingParamReturnsBadRequest() throws Exception {
        mockMvc.perform(get("/api/foos"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void getReleaseReturnsAcceptanceMarker() throws Exception {
        mockMvc.perform(get("/api/release"))
                .andExpect(status().isOk())
                .andExpect(content().string("Lab CI/CD metrics 1.2.16"));
    }
}
